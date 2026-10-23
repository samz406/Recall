import Foundation
import CryptoKit

public enum MemoryScope: String, Codable, CaseIterable, Sendable {
    case global, work, personal, learning, project, conversation
    public var title: String {
        switch self {
        case .global: "所有场景"
        case .work: "工作"
        case .personal: "生活"
        case .learning: "学习"
        case .project: "指定主题"
        case .conversation: "本次会话"
        }
    }
}

public enum MemoryClaimKind: String, Codable, CaseIterable, Sendable {
    case event, preference, goal, constraint, habit, workflow, action, experience, person, reference
    public var title: String {
        switch self {
        case .event: "事项进展"
        case .preference: "表达偏好"
        case .goal: "目标"
        case .constraint: "约定与边界"
        case .habit: "本人陈述的习惯"
        case .workflow: "工作方式"
        case .action: "待确认行动"
        case .experience: "历史经验"
        case .person: "人物与关系"
        case .reference: "记录线索"
        }
    }
    public var isPersonal: Bool { ![.event, .action, .experience, .reference].contains(self) }
}

public enum MemoryClaimState: String, Codable, CaseIterable, Sendable {
    case active, tentative, conflicted, superseded, retracted, expired
    public var title: String {
        switch self {
        case .active: "正在使用"
        case .tentative: "仅作线索"
        case .conflicted: "说法有变化"
        case .superseded: "已被新约定替代"
        case .retracted: "已停用"
        case .expired: "已过期"
        }
    }
}

public struct MemoryDirective: Codable, Hashable, Sendable {
    public var content: String
    public var key: String
    public var kind: MemoryClaimKind
    public var scope: MemoryScope
    public var scopeID: String?
    public var replacesPrevious: Bool
    public var validUntil: Date?
    public init(content: String, key: String, kind: MemoryClaimKind = .preference, scope: MemoryScope = .global,
                scopeID: String? = nil, replacesPrevious: Bool = true, validUntil: Date? = nil) {
        self.content = content; self.key = key; self.kind = kind; self.scope = scope
        self.scopeID = scopeID; self.replacesPrevious = replacesPrevious
        self.validUntil = validUntil
    }
    /// Only explicitly requested memory operations are parsed here. Observed page text never calls this path.
    public static func parse(_ text: String, conversationID: UUID? = nil) -> MemoryDirective? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (5...800).contains(text.count), text.range(of: #"^(?:请)?(?:记住[：:，,\s]?|以后|今后|从现在起|这次|本次)"#, options: .regularExpression) != nil,
              !["如果", "假如", "比如", "例如", "他说", "她说", "文中", "请问"].contains(where: text.contains) else { return nil }
        let explicitRemember = text.hasPrefix("记住") || text.hasPrefix("请记住")
        guard explicitRemember || ["简洁", "详细", "篇幅", "少换行", "精简", "简短", "正式", "自然", "语气", "口吻", "中文", "英文", "只写工作", "私人", "老规矩"].contains(where: text.contains) else { return nil }
        let oneTurn = text.hasPrefix("这次") || text.hasPrefix("本次")
        let scope: MemoryScope = oneTurn ? .conversation :
            (text.contains("周报") || text.contains("工作总结") ? .work :
             (text.contains("学习") ? .learning : (text.contains("个人回顾") || text.contains("生活回顾") ? .personal : .global)))
        var content = text.replacingOccurrences(of: #"^(?:请)?记住[：:，,\s]*"#, with: "", options: .regularExpression)
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        let kind: MemoryClaimKind
        if let name = personName(in: content) { key = "person:" + normalized(name) + (content.contains("生日") ? ":birthday" : ":relationship"); kind = .person }
        else if ["我的目标", "我要成为", "我希望"].contains(where: content.contains) { key = "goal:" + normalized(content); kind = .goal }
        else if ["我每天", "我每周", "我通常", "我习惯"].contains(where: content.contains) { key = "habit:" + normalized(content); kind = .habit }
        else if ["私人", "生活内容", "工作内容", "只写工作", "个人内容"].contains(where: content.contains) { key = "review-content"; kind = .constraint }
        else if ["简洁", "详细", "篇幅", "少换行", "精简", "简短"].contains(where: content.contains) { key = "response-length"; kind = .preference }
        else if ["正式", "自然", "语气", "口吻"].contains(where: content.contains) { key = "response-tone"; kind = .preference }
        else if ["中文", "英文", "语言"].contains(where: content.contains) { key = "response-language"; kind = .preference }
        else if ["先", "后", "老规矩", "步骤"].contains(where: content.contains) { key = "workflow:" + normalized(content); kind = .workflow }
        else { key = "explicit:" + normalized(content); kind = .constraint }
        return MemoryDirective(content: content, key: key, kind: kind, scope: scope,
            scopeID: oneTurn ? conversationID?.uuidString : nil)
    }
    static func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func personName(in text: String) -> String? {
        let patterns = [#"(?:我的)?(?:女儿|儿子|妻子|爱人|丈夫|同事|朋友)(?:叫|是)[：:]?([\p{Han}A-Za-z]{2,16})"#,
                        #"^([\p{Han}A-Za-z]{2,16}?)(?:的生日是|生日是|是我的(?:女儿|儿子|妻子|爱人|丈夫|同事|朋友))"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }
}

public struct MemoryEvidence: Codable, Hashable, Sendable {
    public var captureID: UUID
    public var fragment: Int
    public var quote: String
    public var speaker: String
    public var sourceVersion: String
    public var recordedAt: Date
    public var eventAt: Date?
    public var sourceApp: String?
    public var sourceBundle: String?
    public var correctedBy: UUID? = nil
}

public struct MemoryClaim: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var key: String
    public var subjectID: String
    public var title: String
    public var content: String
    public var kind: MemoryClaimKind
    public var state: MemoryClaimState
    public var scope: MemoryScope
    public var scopeID: String?
    public var evidence: [MemoryEvidence]
    public var dependencies: [UUID]
    public var supersedes: [UUID]
    public var status: WorkEpisodeStatus?
    public var resultStatus: WorkEpisodeStatus?
    public var nextAction: String?
    public var validFrom: Date
    public var validUntil: Date?
    public var updatedAt: Date
    public var explicit: Bool
    public var sourceIDs: [UUID] { Array(Set(evidence.map(\.captureID))).sorted { $0.uuidString < $1.uuidString } }
    public var date: Date { evidence.compactMap(\.eventAt).min() ?? evidence.map(\.recordedAt).min() ?? validFrom }
    public func usable(at now: Date = .now) -> Bool { state == .active && (validUntil == nil || validUntil! > now) }
}

public struct MemoryEntity: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var kind: String
    public var sourceIDs: [UUID]
}

public struct MemoryDependency: Codable, Hashable, Sendable {
    public var outputID: UUID
    public var kind: String
    public var sourceIDs: [UUID]
    public var claimIDs: [UUID]
}

public struct MemoryKnowledge: Codable, Sendable {
    public var claims: [MemoryClaim] = []
    public var entities: [MemoryEntity] = []
    public var dependencies: [MemoryDependency] = []
    public var sourceVersions: [String: String] = [:]
    public var suppressedKeys: [String] = []
    public var updatedAt: Date?
    /// Parser changes must also re-evaluate unchanged historical sources.
    public var organizationVersion: Int?
    public var pendingScreenshotDeletions: [String] = []
    public init() {}
}

public struct MemoryKnowledgeSettings: Codable, Hashable, Sendable {
    public var automaticOrganization = true
    public var retainExplicitMemories = true
    public init() {}
}

public struct MemoryKnowledgeEngine: Sendable {
    public static let organizationVersion = 3
    static func withdrawnSourceIDs(from previous: MemoryKnowledge, to current: MemoryKnowledge) -> Set<UUID> {
        let states = Dictionary(uniqueKeysWithValues: current.claims.map { ($0.id, $0.state) })
        return Set(previous.claims.filter { $0.state == .active && states[$0.id] != .active }.flatMap(\.sourceIDs))
    }
    private struct SourceSnapshot: Encodable {
        var text: String
        var recordedAt: Date
        var title: String?
        var origin: CaptureTextOrigin?
        var app: String?
        var bundle: String?
        var note: ManualMatterNote?
        var directive: MemoryDirective?
    }
    public init() {}
    public func canonicalConsolidation(day: Date, state: RecallState, fallback: IntelligenceConsolidation,
                                       calendar: Calendar = .current) -> IntelligenceConsolidation {
        var result = fallback
        let files = MatterMemoryEngine().observedFiles(in: state)
        let sources = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0) })
        let episodes: [WorkEpisode] = files.flatMap { file in
            file.events.filter { calendar.isDate($0.date, inSameDayAs: day) }.map { event in
                WorkEpisode(id: event.id, day: day, startedAt: event.date, endedAt: event.date,
                    projectKey: file.id, projectName: file.title, title: file.title, intent: file.title,
                    action: event.detail, outcome: event.resultStatus == .completed || event.status == .completed ? event.detail : nil,
                    nextAction: event.nextAction, status: event.status, importance: event.status == .blocked ? 0.9 : 0.8,
                    confidence: 0.8, sourceApps: event.evidenceIDs.compactMap { sources[$0]?.sourceAppName }.memoryUnique(), evidenceIDs: event.evidenceIDs)
            }
        }
        result.episodes = episodes
        result.projectStates = files.map { file in
            ProjectState(projectKey: file.id, displayName: file.title, currentState: file.latest.detail,
                nextAction: file.latest.nextAction, blockers: file.latest.status == .blocked ? [file.latest.detail] : [],
                evidenceIDs: file.evidenceIDs, confidence: 0.8, lastActiveAt: file.latest.date)
        }
        let knowledge = reconcile(state)
        result.memories = knowledge.claims.filter { $0.kind.isPersonal && $0.usable() }.map { claim in
            let kind: UserMemoryKind
            switch claim.kind {
            case .goal: kind = .goal
            case .constraint: kind = .constraint
            case .habit: kind = .habit
            case .workflow: kind = .workflowLesson
            default: kind = .preference
            }
            return UserMemory(id: claim.id, key: claim.key, kind: kind, content: claim.content,
                confidence: 0.8, status: .confirmed, evidenceIDs: claim.sourceIDs, createdAt: claim.validFrom, updatedAt: claim.updatedAt)
        }
        var progressKeys: Set<String> = []
        let progress = episodes.reversed().filter { [.completed, .progressed].contains($0.status) || $0.outcome != nil }
            .filter { progressKeys.insert($0.projectKey).inserted }
        let open = episodes.filter { [.pending, .blocked].contains($0.status) && $0.nextAction != nil }
        result.briefing.headline = files.filter { calendar.isDate($0.latest.date, inSameDayAs: day) }.map(\.title).prefix(3).joined(separator: "；")
        result.briefing.progress = progress.map { BriefingItem(title: $0.projectName, detail: $0.outcome ?? $0.action, confidence: 0.8, evidenceIDs: $0.evidenceIDs) }
        result.briefing.openLoops = open.map { BriefingItem(title: $0.projectName, detail: $0.nextAction ?? $0.action, confidence: 0.8, evidenceIDs: $0.evidenceIDs) }
        result.briefing.nextActions = Array(result.briefing.openLoops.prefix(3))
        result.briefing.episodeIDs = episodes.map(\.id)
        return result
    }
    public static func version(of capture: CaptureRecord, corrections: [MatterCorrection] = []) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = SourceSnapshot(text: capture.ocrText, recordedAt: capture.createdAt, title: capture.windowTitle,
            origin: capture.textOrigin, app: capture.sourceAppName, bundle: capture.sourceBundleIdentifier,
            note: capture.manualMatter, directive: capture.memoryDirective)
        let source = (try? encoder.encode(snapshot)) ?? Data(capture.ocrText.utf8)
        let changes = (try? encoder.encode(corrections.filter { $0.evidenceIDs.contains(capture.id) })) ?? Data()
        return SHA256.hash(data: source + changes).map { String(format: "%02x", $0) }.joined()
    }

    public func sourcesUsable(_ ids: Set<UUID>, in state: RecallState) -> Bool {
        let sources = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0) })
        let knowledge = reconcile(state)
        let active = Set(knowledge.claims.filter { $0.usable() }.flatMap(\.sourceIDs))
        let retiredReferences = Set(knowledge.claims.filter { $0.kind == .reference && !$0.usable() }.flatMap(\.sourceIDs))
        return ids.allSatisfy { id in
            guard let record = sources[id], !retiredReferences.contains(id) else { return false }
            return record.memoryDirective == nil || active.contains(id)
        }
    }
    public func cloudEligibleClaims(in state: RecallState) -> [MemoryClaim] {
        let allowed = Set(state.captures.filter {
            !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "")
        }.map(\.id))
        return reconcile(state).claims.filter { $0.usable() && !$0.sourceIDs.isEmpty && Set($0.sourceIDs).isSubset(of: allowed) }
    }
    static func id(_ text: String) -> UUID { MatterEvidence.eventID(source: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, topic: text, ordinal: 0) }

    /// One source ledger for reviews, chat, and the topic browser. Explicit deletion is reconciled even while paused.
    public func reconcile(_ state: RecallState, force: Bool = false, now: Date = .now, allowNew: Bool = true) -> MemoryKnowledge {
        var result = state.memoryKnowledge
        let safe = state.correctedForAnalysis()
        let sources = Dictionary(uniqueKeysWithValues: safe.captures.map { ($0.id, $0) })
        let originals = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0.createdAt) })
        let versions = Dictionary(uniqueKeysWithValues: safe.captures.map { ($0.id.uuidString, Self.version(of: $0, corrections: state.matterCorrections)) })
        let outdated = result.organizationVersion != Self.organizationVersion
        let changed = outdated || versions != result.sourceVersions
        result.claims = result.claims.compactMap { old in
            var claim = old
            claim.evidence.removeAll { evidence in
                sources[evidence.captureID] == nil || versions[evidence.captureID.uuidString] != evidence.sourceVersion
            }
            guard !claim.evidence.isEmpty else { return nil }
            if let until = claim.validUntil, until <= now { claim.state = .expired }
            return claim
        }
        guard force || (allowNew && state.memoryKnowledgeSettings.automaticOrganization && changed) else {
            result.entities = result.entities.compactMap { old in
                var entity = old
                entity.sourceIDs.removeAll { sources[$0] == nil }
                return entity.sourceIDs.isEmpty ? nil : entity
            }
            result.dependencies = dependencies(in: state, claims: result.claims)
            return result
        }
        var candidates: [MemoryClaim] = []
        func proof(_ record: CaptureRecord, quote: String, ordinal: Int, speaker: String, eventAt: Date? = nil) -> MemoryEvidence {
            let recorded = originals[record.id] ?? record.createdAt
            return MemoryEvidence(captureID: record.id, fragment: ordinal, quote: quote, speaker: speaker,
                sourceVersion: versions[record.id.uuidString] ?? "", recordedAt: recorded, eventAt: eventAt,
                sourceApp: record.sourceAppName, sourceBundle: record.sourceBundleIdentifier)
        }
        func claim(key: String, subject: String, title: String, content: String, kind: MemoryClaimKind,
                   scope: MemoryScope = .global, scopeID: String? = nil, evidence: [MemoryEvidence],
                   status: WorkEpisodeStatus? = nil, resultStatus: WorkEpisodeStatus? = nil,
                   nextAction: String? = nil, explicit: Bool = false) -> MemoryClaim {
            let first = evidence.map(\.recordedAt).min() ?? now
            let identifier = Self.id(key)
            return MemoryClaim(id: identifier, key: identifier.uuidString, subjectID: subject, title: title, content: content, kind: kind,
                state: .active, scope: scope, scopeID: scopeID, evidence: evidence, dependencies: [], supersedes: [],
                status: status, resultStatus: resultStatus, nextAction: nextAction, validFrom: first,
                validUntil: nil, updatedAt: evidence.map(\.recordedAt).max() ?? now, explicit: explicit)
        }
        let files = MatterMemoryEngine().observedFiles(in: state)
        let references = MemoryReferenceEngine().files(in: state, excluding: Set(files.flatMap(\.evidenceIDs)))
        for file in files {
            for event in file.events {
                let evidence = event.evidenceIDs.compactMap { sourceID -> MemoryEvidence? in
                    guard let source = sources[sourceID] else { return nil }
                    let ordinal = RecordedText.segments(in: source).first { $0.text == event.detail }?.ordinal ?? event.sequence
                    var evidence = proof(source, quote: event.detail, ordinal: ordinal, speaker: "自己", eventAt: event.eventAt)
                    if let correction = state.matterCorrections.last(where: { $0.kind == .completed && $0.evidenceIDs.contains(sourceID) }) {
                        evidence.correctedBy = correction.id
                        evidence.speaker = "用户更正"
                        evidence.quote = correction.text.isEmpty ? "用户已标记完成" : correction.text
                    }
                    return evidence
                }
                let key = "event:" + file.id + ":" + event.id.uuidString
                candidates.append(claim(key: key, subject: file.id, title: file.title, content: event.detail,
                    kind: .event, scope: .project, scopeID: file.id, evidence: evidence,
                    status: event.status, resultStatus: event.resultStatus, nextAction: event.nextAction))
            }
        }
        for file in references {
            for event in file.events {
                let evidence = event.evidenceIDs.compactMap { id -> MemoryEvidence? in
                    guard let source = sources[id], source.ocrText.contains(event.detail) else { return nil }
                    return proof(source, quote: event.detail, ordinal: event.sequence,
                        speaker: "保存的内容，非本人行动结论", eventAt: event.eventAt)
                }
                candidates.append(claim(key: "reference:" + file.id + ":" + event.id.uuidString,
                    subject: file.id, title: file.title, content: event.detail, kind: .reference,
                    evidence: evidence, status: .explored))
            }
        }
        let cueKinds: [(MemoryClaimKind, [String])] = [
            (.preference, ["我喜欢", "我更喜欢", "我不喜欢", "我偏好"]),
            (.goal, ["我的目标", "我想要", "我希望", "我要成为"]),
            (.constraint, ["我不能", "我的限制", "我要求"]),
            (.habit, ["我通常", "我习惯", "我每天", "我每周"]),
            (.workflow, ["我以后", "我下次", "老规矩"])
        ]
        for source in safe.captures.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let directive = source.memoryDirective {
                let key = "personal:\(directive.scope.rawValue):\(directive.scopeID ?? ""):\(directive.key):\(source.id.uuidString)"
                candidates.append(claim(key: key, subject: "user", title: directive.content, content: directive.content,
                    kind: directive.kind, scope: directive.scope, scopeID: directive.scopeID,
                    evidence: [proof(source, quote: directive.content, ordinal: 0, speaker: "本人明确要求")], explicit: true))
                candidates[candidates.count - 1].validUntil = directive.validUntil
                if let name = MemoryDirective.personName(in: directive.content) { candidates[candidates.count - 1].subjectID = "person:" + MemoryDirective.normalized(name) }
                else if directive.kind == .person { candidates[candidates.count - 1].subjectID = "person-record:" + source.id.uuidString }
                continue
            }
            for segment in RecordedText.segments(in: source) where segment.speaker == .user {
                let text = segment.text
                guard (5...220).contains(text.count), !["如果", "例如", "比如", "他说", "她说", "文章", "这次", "本次", "今天先", "暂时"].contains(where: text.contains) else { continue }
                let kind: MemoryClaimKind?
                if MemoryDirective.personName(in: text) != nil { kind = .person }
                else { kind = cueKinds.first { $0.1.contains(where: text.contains) }?.0 }
                guard let kind else { continue }
                let key = "personal:observed:\(kind.rawValue):\(MemoryDirective.normalized(text))"
                candidates.append(claim(key: key, subject: "user", title: text, content: text, kind: kind,
                    evidence: [proof(source, quote: text, ordinal: segment.ordinal, speaker: "自己")]))
                if let name = MemoryDirective.personName(in: text) { candidates[candidates.count - 1].subjectID = "person:" + MemoryDirective.normalized(name) }
            }
        }
        // Incoming requests are candidates for the user to arrange, never confirmed personal commitments.
        let actions = ReminderExtractor().candidates(from: safe.captures.filter { $0.memoryDirective == nil }, existing: [])
        for action in actions {
            let evidence = action.sourceCaptureIDs.compactMap { id -> MemoryEvidence? in
                guard let source = sources[id], let segment = RecordedText.segments(in: source).first(where: {
                    $0.text.localizedCaseInsensitiveContains(action.title) || action.title.localizedCaseInsensitiveContains($0.text)
                }) else { return nil }
                let speaker = segment.speaker == .user ? "自己" : "对方向本人提出的请求"
                return proof(source, quote: segment.text, ordinal: segment.ordinal, speaker: speaker)
            }
            var proposed = claim(key: "action:" + action.semanticKey, subject: "action:" + action.semanticKey,
                title: action.title, content: evidence.map(\.quote).joined(separator: "\n"), kind: .action,
                evidence: evidence, status: .pending)
            proposed.state = .tentative
            candidates.append(proposed)
        }
        // Repeated observations are one assertion with more sources, never independent confirmations.
        let grouped = Dictionary(grouping: candidates, by: \.key)
        var merged: [MemoryClaim] = grouped.values.compactMap { values in
            guard var first = values.first else { return nil }
            var seen: Set<String> = []
            first.evidence = values.flatMap(\.evidence).filter { seen.insert($0.captureID.uuidString + ":" + String($0.fragment)).inserted }
            first.updatedAt = first.evidence.map(\.recordedAt).max() ?? first.updatedAt
            if let until = first.validUntil, until <= now { first.state = .expired }
            if let old = result.claims.first(where: { $0.id == first.id }), [.retracted, .expired].contains(old.state) {
                first.state = old.state; first.validUntil = old.validUntil
            }
            return first
        }
        // Only a newer explicit instruction in the same scope replaces an old instruction.
        let directives = Dictionary(grouping: safe.captures.filter { $0.memoryDirective != nil }) { source in
            let d = source.memoryDirective!
            return "\(d.scope.rawValue):\(d.scopeID ?? ""):\(d.key)"
        }
        for records in directives.values {
            guard let latest = records.max(by: { $0.createdAt < $1.createdAt }) else { continue }
            guard latest.memoryDirective?.replacesPrevious == true else { continue }
            let olderIDs = Set(records.filter { $0.id != latest.id }.map(\.id))
            let oldClaims = merged.filter { !$0.sourceIDs.allSatisfy({ !olderIDs.contains($0) }) && !$0.sourceIDs.contains(latest.id) }
            for i in merged.indices where merged[i].explicit {
                if merged[i].sourceIDs.contains(latest.id) { merged[i].supersedes = oldClaims.map(\.id) }
                else if oldClaims.contains(where: { $0.id == merged[i].id }) && merged[i].state == .active { merged[i].state = .superseded }
            }
        }
        // Negative and positive observations about the same object remain a visible conflict, not a guessed preference.
        let observed = merged.indices.filter { merged[$0].kind == .preference && !merged[$0].explicit }
        for i in observed {
            let positive = merged[i].content.replacingOccurrences(of: "我不喜欢", with: "我喜欢")
            if observed.contains(where: { $0 != i && merged[$0].content != merged[i].content && merged[$0].content.replacingOccurrences(of: "我不喜欢", with: "我喜欢") == positive }) {
                merged[i].state = .conflicted
            }
        }
        let activeIDs = Set(merged.map(\.id))
        for file in files {
            guard let resultEvent = file.events.last(where: { $0.status == .completed || $0.resultStatus == .completed }),
                  file.events.contains(where: { $0.id != resultEvent.id && $0.status == .blocked }),
                  file.events.contains(where: { $0.id != resultEvent.id && $0.status == .progressed && $0.date <= resultEvent.date }) else { continue }
            let supporting = merged.filter { $0.subjectID == file.id && $0.kind == .event && $0.date <= resultEvent.date }
            var experience = claim(key: "experience:" + file.id, subject: file.id, title: file.title,
                content: supporting.map(\.content).memoryUnique().joined(separator: "\n"), kind: .experience,
                scope: .project, scopeID: file.id, evidence: supporting.flatMap(\.evidence), status: .completed)
            experience.dependencies = supporting.map(\.id).filter(activeIDs.contains)
            merged.append(experience)
        }
        result.claims = merged.filter { !$0.evidence.isEmpty }.map { original in
            var claim = original
            if result.suppressedKeys.contains(claim.key) { claim.state = .retracted }
            return claim
        }
            .sorted { $0.date == $1.date ? $0.key < $1.key : $0.date > $1.date }
        let oldEntities = Dictionary(uniqueKeysWithValues: result.entities.map { ($0.id, $0) })
        result.entities = (files + references).map { file in
            MemoryEntity(id: file.id, name: file.title, aliases: oldEntities[file.id]?.aliases ?? [], kind: "topic", sourceIDs: file.evidenceIDs)
        }
        let people = Dictionary(grouping: result.claims.filter { $0.kind == .person }, by: \.subjectID)
        for (key, items) in people {
            guard let first = items.first else { continue }
            result.entities.append(MemoryEntity(id: key, name: MemoryDirective.personName(in: first.content) ?? first.title,
                aliases: oldEntities[key]?.aliases ?? [], kind: "person", sourceIDs: items.flatMap(\.sourceIDs).memoryUnique()))
        }
        result.sourceVersions = versions; result.updatedAt = now; result.organizationVersion = Self.organizationVersion
        result.dependencies = dependencies(in: state, claims: result.claims)
        return result
    }

    public func dependencies(in state: RecallState, claims: [MemoryClaim]) -> [MemoryDependency] {
        func link(_ id: UUID, _ kind: String, _ sources: [UUID]) -> MemoryDependency {
            let ids = Set(sources)
            return MemoryDependency(outputID: id, kind: kind, sourceIDs: sources,
                claimIDs: claims.filter { !Set($0.sourceIDs).isDisjoint(with: ids) }.map(\.id))
        }
        var links: [MemoryDependency] = []
        for summary in state.dailySummaries { links.append(link(summary.id, "daily", summary.sourceCaptureIDs)) }
        for report in state.weeklyReports { links.append(link(report.id, "weekly", Array(report.sourceIDs))) }
        for reminder in state.reminders { links.append(link(reminder.id, "reminder", reminder.sourceCaptureIDs)) }
        for message in state.messages where message.role == .assistant { links.append(link(message.id, "answer", message.citations)) }
        return links
    }

    public func files(in state: RecallState) -> [MatterFile]? {
        guard state.memoryKnowledge.updatedAt != nil,
              state.memoryKnowledge.organizationVersion == Self.organizationVersion,
              state.memoryKnowledge.sourceVersions == Dictionary(uniqueKeysWithValues: state.correctedForAnalysis().captures.map {
                  ($0.id.uuidString, Self.version(of: $0, corrections: state.matterCorrections))
              }) else { return nil }
        let groups = Dictionary(grouping: state.memoryKnowledge.claims.filter { $0.kind == .event && $0.usable() }, by: \.subjectID)
        var files: [MatterFile] = []
        for (key, claims) in groups {
            var events: [MatterEvent] = []
            for claim in claims {
                let recordedAt = claim.evidence.map(\.recordedAt).min() ?? claim.validFrom
                let eventAt = claim.evidence.compactMap(\.eventAt).min()
                let status: WorkEpisodeStatus = claim.status ?? .explored
                var event = MatterEvent(id: claim.id, title: claim.title, detail: claim.content,
                    recordedAt: recordedAt, eventAt: eventAt, status: status,
                    evidenceIDs: claim.sourceIDs, nextAction: claim.nextAction)
                event.resultStatus = claim.resultStatus
                event.sequence = claim.evidence.first?.fragment ?? 0
                events.append(event)
            }
            events.sort { a, b in a.date == b.date ? a.sequence < b.sequence : a.date < b.date }
            if let last = events.last { files.append(MatterFile(id: key, title: last.title, events: events)) }
        }
        files.sort { $0.latest.date > $1.latest.date }
        return files
    }
}

// Stable, order-preserving deduplication shared by the memory pipeline.
extension Array where Element: Hashable {
    func memoryUnique() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
