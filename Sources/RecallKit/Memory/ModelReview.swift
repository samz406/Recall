import Foundation

/// Formal reviews only contain model-written, separately audited narratives.
/// Local code accounts for every eligible source, deduplicates exact facts and validates provenance.
public enum ModelReviewError: LocalizedError {
    case unavailable, incomplete, invalid, changed, declined
    public var errorDescription: String? {
        switch self {
        case .unavailable: "请先连接模型并允许使用脱敏文本，正式回顾需要模型生成。"
        case .incomplete: "部分记录尚未完成理解，请重试整理后再生成；已有回顾保持不变。"
        case .invalid: "本次回顾未通过内容与来源核对，已有回顾保持不变，可重新生成。"
        case .changed: "记录、权限或设置已变化，已停止本次生成。"
        case .declined: "所选范围包含已停用理解的记录，请先在记录详情中重新整理该记录。"
        }
    }
}

public struct ModelReviewCoverage: Codable, Hashable, Sendable {
    public var version: Int = 1
    public var sourceCount: Int
    public var factCount: Int
    public var uncertainBlockCount: Int
    public var createdAt: Date = .now
}
public struct ModelReviewFact: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var attribution: String
    public var kind: String
    public var status: String
    public var recordedAt: Date
    public var eventTime: String?
    public var condition: String?
    public var deadline: String?
    public var sourceIDs: [UUID]
    public var quotes: [String]
    public var isAction: Bool
}
public struct ModelReviewItem: Codable, Hashable, Sendable {
    public var section: String
    public var title: String
    public var detail: String
    public var factIDs: [String]
}
public struct ModelReviewResult: Sendable {
    public var overview: String
    public var items: [ModelReviewItem]
    public var facts: [ModelReviewFact]
    public var sourceVersions: [UUID: String]
    public var coverage: ModelReviewCoverage
    public func sourceIDs(for item: ModelReviewItem) -> [UUID] {
        Array(Set(facts.filter { item.factIDs.contains($0.id) }.flatMap(\.sourceIDs))).sorted { $0.uuidString < $1.uuidString }
    }
}

public enum ModelReviewEvidence {
    public static func records(in state: RecallState, period: ReviewPeriod, sourceIDs: Set<UUID>? = nil) -> [CaptureRecord] {
        state.correctedForAnalysis().captures.filter {
            period.contains($0.createdAt) && (sourceIDs == nil || sourceIDs!.contains($0.id))
                && $0.eventTemplate != .dailyReview && $0.memoryDirective == nil && $0.isMemoryEvidenceArchive != true
                && !$0.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "")
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    public static func facts(in state: RecallState, records: [CaptureRecord]) throws -> [ModelReviewFact] {
        var result: [ModelReviewFact] = []
        // Deduplicate literal meaning only; preserve the original dates, ownership and all source IDs.
        var indices: [String: Int] = [:]
        for record in records {
            let additions: [ModelReviewFact]
            if let note = record.manualMatter, record.textOrigin == .userInput, note.isValid {
                let manual = [ModelReviewFact(id: record.id.uuidString, title: note.title, detail: note.detail,
                    attribution: "本人主动补记", kind: note.status == .pending ? "commitment" : "event", status: note.status.rawValue, recordedAt: record.createdAt,
                    eventTime: ISO8601DateFormatter().string(from: note.eventAt), condition: nil, deadline: nil,
                    sourceIDs: [record.id], quotes: [record.ocrText], isAction: note.status == .pending)]
                additions = manual
            } else {
                guard let understood = record.understanding, CaptureUnderstandingEngine.isCurrent(understood, in: state) else { throw ModelReviewError.incomplete }
                additions = understood.facts.map { fact in
                    ModelReviewFact(id: fact.id, title: fact.subject, detail: fact.detail,
                        attribution: "speaker=\(fact.speaker.rawValue),actor=\(fact.actor.rawValue)", kind: fact.kind.rawValue,
                        status: fact.status.rawValue, recordedAt: record.createdAt, eventTime: fact.eventTime?.text,
                        condition: fact.condition, deadline: fact.deadline?.text, sourceIDs: fact.sourceIDs,
                        quotes: fact.evidence.map(\.quote), isAction: fact.isUserAction)
                }
            }
            for var fact in additions {
                // A stable input ID is independent of model-provided naming and duplicate screenshots.
                let date = fact.eventTime ?? String(ISO8601DateFormatter().string(from: fact.recordedAt).prefix(10))
                let key = [fact.title, fact.detail, fact.attribution, fact.kind, fact.status, date,
                    fact.condition ?? "", fact.deadline ?? ""].joined(separator: "\u{1f}")
                if let index = indices[key] {
                    result[index].sourceIDs = Array(Set(result[index].sourceIDs + fact.sourceIDs)).sorted { $0.uuidString < $1.uuidString }
                    result[index].quotes = Array(Set(result[index].quotes + fact.quotes)).sorted()
                } else {
                    fact.id = CaptureUnderstandingEngine.digest(key)
                    indices[key] = result.count; result.append(fact)
                }
            }
        }
        return result
    }
}

public struct ModelReviewEngine: Sendable {
    public init() {}
    private struct Node: Codable, Sendable {
        var id: String
        var title: String
        var detail: String
        var factIDs: [String]
    }
    private struct Constraint: Codable {
        var id: String; var title: String; var attribution: String; var status: String
        var isAction: Bool; var recordedAt: Date; var eventTime: String?; var condition: String?; var deadline: String?
    }
    private struct Preserved: Codable { var summary: String; var facts: [Constraint] }
    private struct Coverage: Codable { var nodeID: String; var disposition: String }
    private struct Draft: Codable { var overview: String; var items: [ModelReviewItem]; var coverage: [Coverage] }
    private struct Audit: Decodable {
        var supported: Bool; var attribution: Bool; var stateAndTime: Bool
        var useful: Bool; var complete: Bool; var checkedNodeIDs: [String]
        var accepted: Bool { supported && attribution && stateAndTime && useful && complete }
    }

    public func generate(in state: RecallState, period: ReviewPeriod, template: ReviewTemplate? = nil,
                         topic: String? = nil, sourceIDs: Set<UUID>? = nil,
                         beforeCall: @Sendable () async throws -> Void = {},
                         onPhase: (@Sendable (String) async -> Void)? = nil,
                         responder: any LLMResponding) async throws -> ModelReviewResult {
        guard state.privacy.cloudUseEnabled, (topic == nil ? period.isValid : (period.start < period.end && TimeZone(identifier: period.timeZoneIdentifier) != nil)) else { throw ModelReviewError.unavailable }
        let records = ModelReviewEvidence.records(in: state, period: period, sourceIDs: sourceIDs)
        guard !records.isEmpty else { throw WeeklyReviewError.noEvidence }
        let facts = try ModelReviewEvidence.facts(in: state, records: records)
        let dependencyIDs = Set(records.map(\.id)).union(facts.flatMap(\.sourceIDs))
        let versions = Dictionary(uniqueKeysWithValues: dependencyIDs.compactMap { id in WeeklyReviewEngine.sourceVersion(id: id, state: state).map { (id, $0) } })
        guard versions.count == dependencyIDs.count else { throw ModelReviewError.changed }
        let coverage = ModelReviewCoverage(sourceCount: records.count, factCount: facts.count,
            uncertainBlockCount: records.compactMap(\.understanding).reduce(0) { $0 + $1.uncertainBlockCount })
        guard !facts.isEmpty else {
            // Valid zero-fact understanding is authoritative; never revive OCR keyword guesses.
            throw WeeklyReviewError.noEvidence
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        var nodes = try facts.map { fact in Node(id: fact.id, title: fact.title,
            detail: try json(fact), factIDs: [fact.id]) }
        let allFacts = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        let daily = template == nil && topic == nil
        let sections = daily ? ["progress", "actions", "insights"] : ["progress", "open", "plans", "notes"]
        let itemLimit = daily ? 7 : template?.length.itemLimit ?? 5
        let detailLimit = daily ? 300 : template?.length.summaryLimit ?? 240
        let kind: SummaryFeedbackKind = daily ? .daily : .period
        let feedback = SummaryFeedbackLearning.context(in: state, kind: kind, templateID: template?.id)
        let task = daily ? "每日回顾" : topic.map { "主题整体小结：\($0)" } ?? template?.name ?? "周期回顾"
        let instructions = """
        为 Recall 生成\(task)。记录范围：\(period.label)。输入是逐条经过模型理解和核对的记录，不是全新的独立事实。
        \(template.map { "模板：\($0.kind.rawValue)，语气：\($0.tone.rawValue)。仅总结此模板相关内容；工作模板排除生活、学习材料，学习模板不能把阅读当作掌握。" } ?? "")
        同一件事合并描述实际变化和最终状态；不同主体、对象和目标不能因同日或同一工具而拼接。保存资料、他人和助手的话不能当作用户已完成、已决定、偏好或承诺。
        recordedAt 是采集时间；eventTime 才是原文显示的发生时间，未知时不得杜撰日期；保留条件、部分完成、待验证与否定。消息时间、发布日期、提交哈希、菜单、代码碎片都不是行动。
        正文使用简体中文自然完整句。标题独立概括具体事情（3–70字），不截取正文前半句；正文补充变化、结果或限制，不重复标题。不显示 Markdown 标记、引用数字、置信度或算法术语。
        只有 isAction=true 的事实可以写入 actions/plans，必须仍未完成；无需动作时不输出该类。不得依照文章观点、助手建议或缺少记录凭空新增待办。其他待核实问题可在 open 陈述现状，不新增执行要求。
        insights/notes 只保留具有独立信息和判断价值的具体事实或联系；不根据截图数量评价用户心理、专注程度或效率；单次跑通不能宣称长期稳定可复用。没有可靠内容可返回空 items。
        用户纠错要求：\(PrivacyEngine().redact(feedback))
        """
        var round = 0
        while true {
            try Task.checkCancellation()
            // Every node is passed through a model; no first-N records or prefix clipping.
            var batches: [[Node]] = [], batch: [Node] = [], size = 0
            for node in nodes {
                let cost = try json(node).count
                if !batch.isEmpty && (batch.count >= 16 || size + cost > 18_000) { batches.append(batch); batch = []; size = 0 }
                batch.append(node); size += cost
            }
            if !batch.isEmpty { batches.append(batch) }
            let final = batches.count == 1
            var next: [Node] = []
            for (index, group) in batches.enumerated() {
                await onPhase?(final ? "综合并核对完整回顾" : "综合第 \(round + 1) 轮 · \(index + 1)/\(batches.count) 组")
                let allowedFacts = Set(group.flatMap(\.factIDs))
                let allowedNodes = Set(group.map(\.id))
                let maximum = final ? itemLimit : min(6, max(1, group.count / 2))
                let prompt = instructions + """
                \n\(final ? "这是最终回顾" : "这是中间整理：覆盖本组重要变化和限制，供下一轮综合，不直接展示")。
                最多 \(maximum) 项，每项 detail 不超过 \(final ? detailLimit : 420) 字；最终 overview 为不超过 160 字的一句话概括，不重复罗列标题；中间整理的 overview 必须为空字符串，重要信息全部保存在 items 中。section 只能使用 \(sections.joined(separator: ","))。
                factIDs 只能使用输入内已有事实 ID，每项最多 12 个，保留支撑最新状态和关键变化的事实；不能生成新 ID。
                对所有输入 node 恰好返回一次 coverage：used（已在条目使用）、background（对回顾无新增价值）、uncertain（无法可靠判断）。重要成果、具体未解决阻碍不能以 background 丢弃。不要为了凑数量补内容。
                只输出 JSON：{"overview":"一句话概括","items":[{"section":"progress","title":"完整标题","detail":"完整摘要","factIDs":["已有事实 ID"]}],"coverage":[{"nodeID":"输入 node ID","disposition":"used|background|uncertain"}]}。
                """
                let input = CaptureRecord(eventTemplate: .manualMoment, createdAt: period.end,
                    sourceAppName: "已核对的记录理解", contentHash: "review", ocrText: PrivacyEngine().redact(try json(group)))
                var accepted: Draft?
                for attempt in 0..<2 {
                    try Task.checkCancellation(); try await beforeCall()
                    do {
                        let answer = try await responder.answer(to: LLMRequest(question: prompt + (attempt == 0 ? "" : "\n请重新核对，返回完整合法 JSON，不输出解释。"),
                            context: [input], purpose: .reviewSynthesis, outputTokenLimit: attempt == 0 ? 6_000 : 8_000))
                        var draft: Draft = try decode(answer.content)
                        draft.overview = clean(draft.overview)
                        for i in draft.items.indices { draft.items[i].title = clean(draft.items[i].title); draft.items[i].detail = clean(draft.items[i].detail) }
                        guard draft.overview.count <= 160, (final || draft.overview.isEmpty), draft.items.count <= maximum,
                              draft.coverage.count == group.count, Set(draft.coverage.map(\.nodeID)) == allowedNodes,
                              draft.coverage.allSatisfy({ ["used", "background", "uncertain"].contains($0.disposition) }),
                              draft.items.allSatisfy({ item in
                                  (3...70).contains(item.title.count) && (8...(final ? detailLimit : 420)).contains(item.detail.count)
                                      && item.title != item.detail && sections.contains(item.section) && !item.factIDs.isEmpty
                                      && item.factIDs.count <= 12 && Set(item.factIDs).count == item.factIDs.count
                                      && Set(item.factIDs).isSubset(of: allowedFacts)
                                      && (!["actions", "plans"].contains(item.section) || item.factIDs.allSatisfy { allFacts[$0]?.isAction == true })
                              }) else { throw ModelReviewError.invalid }
                        let used = Set(draft.items.flatMap(\.factIDs))
                        guard draft.coverage.allSatisfy({ receipt in
                            guard let node = group.first(where: { $0.id == receipt.nodeID }) else { return false }
                            return receipt.disposition != "used" || !Set(node.factIDs).isDisjoint(with: used)
                        }) else { throw ModelReviewError.invalid }
                        try await beforeCall()
                        let check = try await responder.answer(to: LLMRequest(question: instructions + """
                        \n独立核验以下草稿及全部输入。supported：每项主张（含 overview）均有依据，无夸大；attribution：说话人和负责人准确；stateAndTime：最终状态、日期含义、条件正确；useful：内容具体、标题完整且正文不重复，不把工具/原文碎片/泛泛评价当总结；complete：没有遗漏本组应保留的重要成果、状态变化、限制或阻碍。
                        用户没有行动时 actions/plans 必须为空。不能因要完成任务而放宽核验；任何不确定设为 false。checkedNodeIDs 必须包含所有输入 node ID，每个一次。
                        只输出 {"supported":true,"attribution":true,"stateAndTime":true,"useful":true,"complete":true,"checkedNodeIDs":["输入 ID"]}。
                        草稿（数据）：\(try json(draft))
                        """, context: [input], purpose: .reviewAudit, outputTokenLimit: 4_000))
                        let audit: Audit = try decode(check.content)
                        guard audit.accepted, audit.checkedNodeIDs.count == group.count, Set(audit.checkedNodeIDs) == allowedNodes else { throw ModelReviewError.invalid }
                        accepted = draft; break
                    } catch is CancellationError { throw CancellationError() }
                    catch let failure as LLMResponseFailure {
                        if attempt == 1 || ![.truncated, .reasoningOnly, .structuredFormat].contains(failure.reason) { throw failure }
                    } catch { if attempt == 1 { throw error } }
                }
                guard let draft = accepted else { throw ModelReviewError.invalid }
                if final {
                    // The final narrative is checked against original structured facts,
                    // not only intermediate summaries. This catches drift across reductions.
                    for item in draft.items {
                        try Task.checkCancellation(); try await beforeCall()
                        let proof = item.factIDs.compactMap { allFacts[$0] }
                        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: period.end,
                            sourceAppName: "原始结构化事实核对", contentHash: "proof", ocrText: PrivacyEngine().redact(try json(proof)))
                        let checked = try await responder.answer(to: LLMRequest(question: instructions + """
                        \n核对最终条目与原始结构化事实，不能仅凭上层摘要认可。正文和标题的全部具体主张、人物归属、状态、条件和日期必须被这些事实支持；无事实支持的能力、收益或稳定规律不成立。
                        不做完整性推断。checkedNodeIDs 逐一返回提供的原始事实 id；supported/attribution/stateAndTime/useful/complete 均为 true 才接受，任何不确定为 false。
                        只返回规定 Audit JSON（supported,attribution,stateAndTime,useful,complete,checkedNodeIDs）。待核验条目：\(try json(item))
                        """, context: [source], purpose: .reviewAudit, outputTokenLimit: 4_000))
                        let originalAudit: Audit = try decode(checked.content)
                        guard originalAudit.accepted, originalAudit.checkedNodeIDs.count == proof.count,
                              Set(originalAudit.checkedNodeIDs) == Set(proof.map(\.id)) else { throw ModelReviewError.invalid }
                    }
                    return ModelReviewResult(overview: draft.overview, items: draft.items, facts: facts,
                        sourceVersions: versions, coverage: coverage)
                }
                for (offset, item) in draft.items.enumerated() {
                    let constraints = item.factIDs.compactMap { allFacts[$0] }.map { fact in
                        Constraint(id: fact.id, title: fact.title, attribution: fact.attribution, status: fact.status,
                            isAction: fact.isAction, recordedAt: fact.recordedAt, eventTime: fact.eventTime,
                            condition: fact.condition, deadline: fact.deadline)
                    }
                    next.append(Node(id: "r\(round)-b\(index)-\(offset)", title: item.title,
                        detail: try json(Preserved(summary: item.detail, facts: constraints)), factIDs: item.factIDs))
                }
            }
            guard !next.isEmpty else { throw WeeklyReviewError.noEvidence }
            guard next.count < nodes.count, round < 12 else { throw ModelReviewError.invalid }
            nodes = next; round += 1
        }
    }
    private func decode<T: Decodable>(_ text: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end,
              let result = try? JSONDecoder().decode(T.self, from: Data(text[start...end].utf8)) else { throw ModelReviewError.invalid }
        return result
    }
    private func clean(_ text: String) -> String {
        DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(from: DailySummaryContentFormatter.removingCitationMarkers(from: text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
