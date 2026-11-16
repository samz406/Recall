import Foundation
import RecallKit

/// No provider or real data: reproduce quotation drift, selective repair, and invalid citations
/// inside merged conclusions through the real period generation and publication model.
enum PeriodReviewEvidenceVerification {
    private struct Failure: LocalizedError { let errorDescription: String? }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }
    private static var day: Date { Calendar.current.startOfDay(for: Date.now.addingTimeInterval(-86_400)) }
    private static var period: ReviewPeriod { ReviewPeriod(start: day, end: day.addingTimeInterval(86_400)) }
    private static func fixture(count: Int = 5, personal: Bool = false) -> RecallState {
        var state = RecallState(); state.privacy.cloudUseEnabled = true
        var items: [DailySummaryItem] = [], ids: [UUID] = []
        for index in 0..<count {
            let life = personal && index == count - 1
            let title = life ? "合成家人聚会安排已记录" : "Atlas \(index + 1)号接口核对结果已记录"
            let detail = life ? "陪同家人参加聚会，已经安排餐食与往返行程。"
                : "Atlas \(index + 1)号接口仍未上线，校验值为 1.25，保留 not able 原词和 10² 表达。"
            let source = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: day.addingTimeInterval(36_000),
                contentHash: "synthetic-period-evidence-\(index)", ocrText: detail)
            state.captures.append(source); ids.append(source.id)
            items.append(DailySummaryItem(section: .progress, title: title, detail: detail, evidenceIDs: [source.id],
                knowledge: DailyItemKnowledge(topic: title, kind: .matter, status: "inProgress", ownedByUser: true,
                    quotes: [detail], category: life ? "work" : nil)))
        }
        var summary = DailySummary(day: day, content: "合成每日回顾", sourceCaptureIDs: ids, todos: [], generationKind: .cloud, items: items)
        summary.items = items; state.dailySummaries = [summary]
        return state
    }
    private actor Model: LLMResponding {
        enum Mode { case references, legacy, typography, wrongQuoteOnce, wrongQuoteAlways, mixedOnce, unknownOnce
            case wrongNumber, wrongNegation, wrongWordBoundary, wrongPower, crossLine, badReference, conflictingReference }
        let mode: Mode
        var requests: [LLMRequest] = []
        init(_ mode: Mode) { self.mode = mode }
        func log() -> [LLMRequest] { requests }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            let rows = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            var receipts: [[String: Any]] = [], items: [[String: Any]] = []
            let damage = requests.count == 1 || mode == .wrongQuoteAlways
            func proof(_ row: [String: Any], damaged: Bool) -> [String: Any] {
                let id = row["id"] as! String, title = row["title"] as! String, detail = row["detail"] as! String
                if mode == .legacy { return ["id": id, "quote": title] }
                if mode == .typography {
                    return ["id": " [" + id.uppercased() + "] ", "quote": title.replacingOccurrences(of: "核对", with: "核\n对").replacingOccurrences(of: "结果", with: "结 果")]
                }
                if damaged {
                    switch mode {
                    case .wrongQuoteOnce, .wrongQuoteAlways, .mixedOnce: return ["id": id, "quote": "原文里没有的虚构引用，不得被发布"]
                    case .unknownOnce: return ["id": "not-an-input-id", "quoteRef": "title"]
                    case .wrongNumber: return ["id": id, "quote": detail.replacingOccurrences(of: "1.25", with: "125")]
                    case .wrongNegation: return ["id": id, "quote": detail.replacingOccurrences(of: "仍未上线", with: "已经上线")]
                    case .wrongWordBoundary: return ["id": id, "quote": detail.replacingOccurrences(of: "not able", with: "notable")]
                    case .wrongPower: return ["id": id, "quote": detail.replacingOccurrences(of: "10²", with: "102")]
                    case .crossLine: return ["id": id, "quote": title + "\n再加一条虚构的上线结果"]
                    case .badReference: return ["id": id, "quoteRef": "q999"]
                    case .conflictingReference: return ["id": id, "quoteRef": "title", "quote": detail]
                    default: break
                    }
                }
                return ["id": id, "quoteRef": "q1"]
            }
            for (index, row) in rows.enumerated() {
                let title = row["title"] as! String, id = row["id"] as! String
                if title.contains("合成家人") {
                    receipts.append(["id": id, "disposition": "outOfScope", "category": "personal",
                        "reason": "本人家庭聚会的餐食和出行安排，不属于工作交付", "quoteRef": "detail"])
                    continue
                }
                receipts.append(["id": id, "disposition": "used", "category": "work"])
                if mode == .mixedOnce && damage && index == 1 { continue }
                var evidence = [proof(row, damaged: damage && (index == 0 || mode == .unknownOnce))]
                if mode == .mixedOnce && damage && index == 0 && rows.count > 1 {
                    evidence = [proof(row, damaged: false), proof(rows[1], damaged: true)]
                }
                items.append(["section": "progress", "title": title, "detail": row["detail"]!, "evidence": evidence])
            }
            let result: [String: Any] = ["overview": "各接口已有核对记录，仍待上线复核。", "items": items, "coverage": receipts]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    static func run() async throws {
        let state = fixture(), engine = PeriodReviewFromDaily(), template = ReviewTemplate(kind: .work)
        for mode in [Model.Mode.references, .legacy, .typography] {
            let model = Model(mode)
            let result = try await engine.generate(in: state, period: period, template: template, responder: model)
            let requests = await model.log()
            try expect(requests.count == 1 && result.draft.items.count == 5 && result.draft.facts.count == 5,
                "来源位置或排版差异仍导致整份回顾重试：\(mode)")
            let rows = try JSONSerialization.jsonObject(with: Data(requests[0].context[0].ocrText.utf8)) as! [[String: Any]]
            let text = rows.flatMap { [($0["title"] as! String), ($0["detail"] as! String)] + ($0["quotes"] as! [String]) }
            try expect(result.draft.facts.allSatisfy { fact in fact.quotes.allSatisfy { quote in text.contains { $0.contains(quote) } } },
                "保存的引用不是发送给模型的原文")
            try expect(result.metrics.modelCalls == 1, "正常路径没有保持单次模型请求")
        }
        for mode in [Model.Mode.wrongQuoteOnce, .wrongNumber, .wrongNegation, .wrongWordBoundary, .wrongPower, .crossLine, .badReference, .conflictingReference, .mixedOnce] {
            let model = Model(mode)
            let result = try await engine.generate(in: state, period: period, template: template, responder: model)
            let requests = await model.log()
            let sizes = try requests.map { try (JSONSerialization.jsonObject(with: Data($0.context[0].ocrText.utf8)) as! [Any]).count }
            let affected = mode == .mixedOnce ? 2 : 1
            try expect(sizes == [5, affected] && result.draft.items.count == 5 && result.draft.facts.count == 5,
                "坏引用没有按完整结论局部修复，或丢失合并条目的来源：\(mode) \(sizes)")
            try expect(requests[1].outputTokenLimit == 2_000 && result.metrics.modelCalls == 2,
                "小范围修复仍使用整周输出预算或重复整周生成")
            try expect(!result.draft.facts.contains { $0.detail.contains("虚构") }, "未验证的引用进入结果")
            for detail in state.dailySummaries[0].items.map(\.detail) {
                try expect(result.draft.items.contains { $0.detail == detail }, "修复覆盖了有效结论或省略原有条目")
            }
        }
        let persistent = Model(.wrongQuoteAlways)
        do {
            _ = try await engine.generate(in: state, period: period, template: template, responder: persistent)
            throw Failure(errorDescription: "修复后仍无依据的结论被发布")
        } catch ModelReviewError.validation(.evidence) { }
        let failed = await persistent.log()
        try expect(failed.count == 2, "持续错误引用没有封顶")
        let large = Model(.unknownOnce)
        let recovered = try await engine.generate(in: fixture(count: 31), period: period, template: template, responder: large)
        let largeRequests = await large.log()
        let sizes = try largeRequests.map { try (JSONSerialization.jsonObject(with: Data($0.context[0].ocrText.utf8)) as! [Any]).count }
        try expect(sizes == [31, 24, 7] && recovered.draft.items.count == 31, "无法定位的坏 ID 未分组复核全部来源")
        let exclusion = Model(.references)
        let filtered = try await engine.generate(in: fixture(personal: true), period: period, template: template, responder: exclusion)
        let exclusions = await exclusion.log()
        try expect(exclusions.count == 1 && filtered.draft.items.count == 4, "模型的范围排除位置引用没有被验证")
        print("PASS: period citation references and legacy typography recover in one call; changed numbers/negation/word boundaries/exponents and mixed-source conclusions repair only affected rows; unknown IDs use bounded batches; persistent invalid evidence is rejected; exclusions remain model-classified")
    }
}
