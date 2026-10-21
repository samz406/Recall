import Foundation

/// A user-authored update stored with its original, deletable source record.
public struct ManualMatterNote: Codable, Hashable, Sendable {
    public var title: String
    public var detail: String
    public var status: WorkEpisodeStatus
    public var eventAt: Date
    public var reviewCategory: ReviewCategory?

    public init(title: String, detail: String, status: WorkEpisodeStatus, eventAt: Date, reviewCategory: ReviewCategory? = nil) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.status = status
        self.eventAt = eventAt
        self.reviewCategory = reviewCategory
    }

    public var isValid: Bool {
        (3...80).contains(title.count) && title.filter { $0.isLetter || $0.isNumber }.count >= 2
            && (1...4000).contains(detail.count)
    }

    public func capture(recordedAt: Date = .now) throws -> CaptureRecord {
        guard isValid, eventAt <= recordedAt else { throw ValidationError.invalidNote }
        return CaptureRecord(eventTemplate: .workCheckpoint, createdAt: recordedAt,
            sourceAppName: "手动记录", sourceBundleIdentifier: "im.recall.app",
            windowTitle: title, contentHash: UUID().uuidString,
            ocrText: "事情：\(title)\n状态：\(status.manualMatterLabel)\n\(detail)",
            textOrigin: .userInput, manualMatter: self)
    }

    private enum ValidationError: LocalizedError {
        case invalidNote
        var errorDescription: String? { "请输入 3–80 字的事情名称、1–4000 字的具体内容，发生时间不能晚于现在。" }
    }
}

public extension WorkEpisodeStatus {
    var manualMatterLabel: String {
        switch self {
        case .explored: "仅作记录"
        case .progressed: "正在推进"
        case .pending: "待处理"
        case .blocked: "遇到阻碍"
        case .completed: "已完成"
        }
    }
}

/// User corrections are separate from captured evidence: original screenshots/text stay inspectable.
public enum MatterCorrectionKind: String, Codable, CaseIterable, Sendable {
    case notMine, completed, separate, inaccurate, eventDate
    public var title: String {
        switch self {
        case .notMine: "不是我说的"
        case .completed: "已经完成"
        case .separate: "另归为一件事"
        case .inaccurate: "结论不准确"
        case .eventDate: "更正事情发生时间"
        }
    }
}

public struct MatterCorrection: Identifiable, Codable, Sendable {
    public var id: UUID = UUID()
    public var evidenceIDs: [UUID]
    public var kind: MatterCorrectionKind
    public var text: String
    public var eventAt: Date?
    public var createdAt: Date = .now
    public init(evidenceIDs: [UUID], kind: MatterCorrectionKind, text: String = "", eventAt: Date? = nil) {
        self.evidenceIDs = evidenceIDs
        self.kind = kind
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.eventAt = eventAt
    }
}

public struct MatterEvent: Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var recordedAt: Date
    public var eventAt: Date?
    public var status: WorkEpisodeStatus
    public var evidenceIDs: [UUID]
    public var nextAction: String?
    public var sequence: Int = 0
    public var resultStatus: WorkEpisodeStatus? = nil
    public var date: Date { eventAt ?? recordedAt }
    public init(id: UUID, title: String, detail: String, recordedAt: Date, eventAt: Date? = nil, status: WorkEpisodeStatus, evidenceIDs: [UUID], nextAction: String? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.recordedAt = recordedAt
        self.eventAt = eventAt; self.status = status; self.evidenceIDs = evidenceIDs
        self.nextAction = nextAction
    }
}

public struct MatterFile: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var events: [MatterEvent]
    public var latest: MatterEvent { events[events.count - 1] }
    public init(id: String, title: String, events: [MatterEvent]) {
        precondition(!events.isEmpty, "A matter needs at least one evidence-backed event")
        self.id = id; self.title = title; self.events = events
    }
    public var evidenceIDs: [UUID] { Array(Set(events.flatMap(\.evidenceIDs))).sorted { $0.uuidString < $1.uuidString } }
    public var resumeProgress: MatterEvent {
        if latest.status == .pending, latest.nextAction == nil,
           let actual = events.last(where: { $0.status == .progressed || $0.status == .completed || $0.status == .blocked }) {
            return actual
        }
        return latest
    }
    public var resumeNextAction: String? {
        latest.nextAction ?? (latest.status == .pending && resumeProgress.id != latest.id ? latest.detail : nil)
    }
    public var resumeText: String {
        resumeProgress.detail
    }
    /// An old open record is not evidence that the user is still working on it today.
    /// Retain its history while moving it out of the default recent-progress list.
    public func needsStatusUpdate(at now: Date = .now, calendar: Calendar = .current) -> Bool {
        let cutoff = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: now)) ?? now
        return latest.status.isOpenMatter && latest.date < cutoff
    }
}

public extension WorkEpisodeStatus {
    var isOpenMatter: Bool { self == .progressed || self == .pending || self == .blocked }

    var matterLabel: String {
        switch self {
        case .completed: "记录为已完成"
        case .progressed: "正在推进"
        case .pending: "明确待办"
        case .blocked: "遇到阻碍"
        case .explored: "相关记录"
        }
    }
}

public struct MatterReview: Identifiable, Sendable {
    public var id: String { matter.id }
    public var matter: MatterFile
    public var previous: MatterEvent?
    public var changes: [MatterEvent]
}

public struct ExperienceHint: Identifiable, Sendable {
    public var id: String { currentID + ":" + past.id.uuidString }
    public var currentID: String
    public var past: MatterEvent
    public var matchingTerms: [String]
}

public struct MatterMemoryEngine: Sendable {
    public init() {}

    public func files(in state: RecallState, calendar: Calendar = .current) -> [MatterFile] {
        let safe = state.correctedForAnalysis()
        let available = Set(safe.captures.map(\.id))
        let captured = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0) })
        let analysisCaptures = Dictionary(uniqueKeysWithValues: safe.captures.map { ($0.id, $0) })
        let existingIDs = Set(safe.episodes.flatMap(\.evidenceIDs))
        let missing = Dictionary(grouping: safe.captures.filter { !existingIDs.contains($0.id) }) { calendar.startOfDay(for: $0.createdAt) }
        let rebuilt = missing.flatMap { PersonalIntelligenceEngine().buildEpisodes(day: $0.key, records: $0.value, calendar: calendar) }
        var groups: [String: [MatterEvent]] = [:]
        var names: [String: String] = [:]
        var seen: Set<String> = []
        // Manual updates use the user's explicit subject and status, not action-word guesses.
        // Apply the same exclusions and corrections as automatically extracted evidence.
        for record in safe.captures {
            guard record.textOrigin == .userInput, let note = record.manualMatter, note.isValid else { continue }
            let corrections = state.matterCorrections.filter { $0.evidenceIDs.contains(record.id) }
            let renamed = corrections.last { $0.kind == .separate && !$0.text.isEmpty }
            let title = renamed?.text ?? note.title
            let key = (renamed == nil ? "topic:" : "user:") + MatterEvidence.key(title)
            let event = MatterEvent(id: record.id, title: title, detail: note.detail,
                recordedAt: captured[record.id]?.createdAt ?? record.createdAt,
                eventAt: corrections.last { $0.kind == .eventDate }?.eventAt ?? note.eventAt,
                status: corrections.contains { $0.kind == .completed } ? .completed : note.status,
                evidenceIDs: [record.id])
            groups[key, default: []].append(event)
            names[key] = title
        }
        // Old episodes are topic hints only. Their clipped action/outcome and inferred status
        // must never bypass the same evidence gate applied to newly captured records.
        for episode in safe.episodes + rebuilt {
            let ids = episode.evidenceIDs.filter(available.contains)
            guard !ids.isEmpty, ids.count == episode.evidenceIDs.count else { continue }
            for id in ids {
                guard let record = analysisCaptures[id] else { continue }
                if record.manualMatter != nil && record.textOrigin == .userInput { continue }
                let corrections = state.matterCorrections.filter { $0.evidenceIDs.contains(id) }
                let separated = corrections.last { $0.kind == .separate && !$0.text.isEmpty }
                for entry in MatterEvidence.entries(in: record,
                    proposedTitle: separated?.text ?? episode.projectName, userNamed: separated != nil) {
                    let key = (separated == nil ? "topic:" : "user:") + MatterEvidence.key(entry.title)
                    guard seen.insert(key + ":" + id.uuidString + ":" + String(entry.ordinal)).inserted else { continue }
                    let eventDate = corrections.last(where: { $0.kind == .eventDate })?.eventAt
                    let recordedAt = captured[id]?.createdAt ?? record.createdAt
                    let completed = corrections.contains { $0.kind == .completed }
                    var event = MatterEvent(id: MatterEvidence.eventID(source: id, topic: key, ordinal: entry.ordinal), title: entry.title,
                        detail: completed ? "用户已标记完成：\(entry.title)" : entry.detail,
                        recordedAt: recordedAt, eventAt: eventDate,
                        status: completed ? .completed : entry.status, evidenceIDs: [id],
                        nextAction: completed ? nil : entry.nextAction)
                    event.sequence = entry.ordinal; event.resultStatus = entry.resultStatus
                    groups[key, default: []].append(event)
                    names[key] = entry.title
                }
            }
        }
        return groups.map { key, events in
            let ordered = events.sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                return $0.sequence == $1.sequence ? $0.id.uuidString < $1.id.uuidString : $0.sequence < $1.sequence
            }
            var changes: [MatterEvent] = []
            for event in ordered {
                // Repeated screenshots add sources, not progress. Preserve the first occurrence
                // so rereading an old result doesn't manufacture a change in this week's review.
                if !event.evidenceIDs.contains(where: { captured[$0]?.manualMatter != nil }),
                   let index = changes.firstIndex(where: {
                       $0.status == event.status && $0.resultStatus == event.resultStatus
                           && MatterEvidence.key($0.detail) == MatterEvidence.key(event.detail)
                           && MatterEvidence.key($0.nextAction ?? "") == MatterEvidence.key(event.nextAction ?? "")
                           && ($0.eventAt == nil || event.eventAt == nil || $0.eventAt == event.eventAt)
                   }) {
                    changes[index].evidenceIDs = Array(Set(changes[index].evidenceIDs + event.evidenceIDs))
                        .sorted { $0.uuidString < $1.uuidString }
                } else { changes.append(event) }
            }
            return MatterFile(id: key, title: names[key] ?? key, events: changes)
        }.sorted { $0.latest.date == $1.latest.date ? $0.id < $1.id : $0.latest.date > $1.latest.date }
    }

    public func weeklyReview(files: [MatterFile], endingAt end: Date = .now, calendar: Calendar = .current) -> [MatterReview] {
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: end)) ?? end
        return files.compactMap { file in
            let changes = file.events.filter { $0.date >= start && $0.date <= end && $0.status != .explored }
            guard !changes.isEmpty else { return nil }
            return MatterReview(matter: file, previous: file.events.last { $0.date < start }, changes: changes)
        }
    }

    /// Historical results require a concrete shared subject and independent sources. No invented analogy.
    public func experiences(for current: MatterFile, in files: [MatterFile]) -> [ExperienceHint] {
        let terms = Self.subjectTerms(current.title)
        return files.flatMap(\.events).compactMap { event -> ExperienceHint? in
            guard event.date < current.latest.date, event.status == .completed,
                  Set(event.evidenceIDs).isDisjoint(with: current.latest.evidenceIDs),
                  event.detail != current.latest.detail else { return nil }
            let matches = terms.filter { (event.title + event.detail).localizedCaseInsensitiveContains($0) }
            guard matches.count >= 2 else { return nil }
            return ExperienceHint(currentID: current.id, past: event, matchingTerms: Array(matches.sorted().prefix(4)))
        }.sorted { $0.past.date > $1.past.date }.prefix(3).map { $0 }
    }

    public static func subjectTerms(_ text: String) -> Set<String> {
        let ignored: Set<String> = ["完成", "处理", "问题", "今天", "项目", "工作", "继续", "最近", "之前", "什么", "哪些", "时候", "怎么", "为什么", "上次", "事情", "结果", "是否", "已经", "做了"]
        var terms: Set<String> = []
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let chars = Array(word)
            if chars.contains(where: { $0.unicodeScalars.contains { $0.value > 0x3400 } }) {
                if chars.count > 1 {
                    for i in 0..<(chars.count - 1) {
                        let part = String(chars[i...i + 1])
                        if !ignored.contains(part) { terms.insert(part) }
                    }
                }
            } else if word.count >= 3 { terms.insert(String(word)) }
        }
        return terms
    }


}

public extension RecallState {
    /// Corrections invalidate derived claims, not original records. Call before inference/retrieval.
    func correctedForAnalysis() -> RecallState {
        var result = self
        let invalid = Set(matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let touched = Set(matterCorrections.flatMap(\.evidenceIDs))
        if !matterCorrections.isEmpty {
            let cutoff = matterCorrections.map(\.createdAt).max() ?? .distantPast
            result.messages.removeAll { $0.createdAt <= cutoff }
            let removedCount = messages.count - result.messages.count
            result.conversationSummaryCoveredMessageCount = max(0, (conversationSummaryCoveredMessageCount ?? 0) - removedCount)
        }
        result.captures.removeAll { invalid.contains($0.id) }
        result.episodes.removeAll { !Set($0.evidenceIDs).isDisjoint(with: invalid) }
        result.projects.removeAll { !Set($0.evidenceIDs).isDisjoint(with: touched) }
        result.userMemories.removeAll { !Set($0.evidenceIDs).isDisjoint(with: touched) }
        result.insights.removeAll { !Set($0.evidenceIDs).isDisjoint(with: touched) }
        result.dailySummaries.removeAll { summary in
            matterCorrections.contains { correction in
                correction.createdAt >= summary.createdAt && !Set(summary.sourceCaptureIDs).isDisjoint(with: correction.evidenceIDs)
            }
        }
        for i in result.captures.indices {
            let corrections = matterCorrections.filter { $0.evidenceIDs.contains(result.captures[i].id) }
            if let eventDate = corrections.last(where: { $0.kind == .eventDate })?.eventAt {
                result.captures[i].createdAt = eventDate
            }
            if let completed = corrections.last(where: { $0.kind == .completed }) {
                result.captures[i].ocrText = "[聊天·自己] 我已完成：" + (completed.text.isEmpty ? "此条记录关联的事项" : completed.text)
                result.captures[i].summary = result.captures[i].ocrText
            }
            if let separated = corrections.last(where: { $0.kind == .separate }), !separated.text.isEmpty {
                result.captures[i].windowTitle = separated.text
            }
        }
        for i in result.episodes.indices {
            let corrections = matterCorrections.filter { !Set($0.evidenceIDs).isDisjoint(with: result.episodes[i].evidenceIDs) }
            if let eventDate = corrections.last(where: { $0.kind == .eventDate })?.eventAt {
                result.episodes[i].startedAt = eventDate
                result.episodes[i].endedAt = eventDate
                result.episodes[i].day = Calendar.current.startOfDay(for: eventDate)
            }
            if let separated = corrections.last(where: { $0.kind == .separate }), !separated.text.isEmpty {
                result.episodes[i].projectKey = "user:" + separated.text.lowercased().filter { $0.isLetter || $0.isNumber }
                result.episodes[i].projectName = separated.text
                result.episodes[i].title = separated.text
            }
            if corrections.contains(where: { $0.kind == .completed }) {
                result.episodes[i].status = .completed
                result.episodes[i].nextAction = nil
                result.episodes[i].outcome = "用户已标记完成：" + result.episodes[i].projectName
            }
        }
        return result
    }
}

public enum MemoryQuestionIntent: String, Sendable {
    case overview, solution, decision, status, change, recall
    public init(question: String) {
        if ["为什么", "为何", "决定", "选择"].contains(where: question.contains) { self = .decision }
        else if ["怎么解决", "如何解决", "解决办法", "上次怎么", "经验"].contains(where: question.contains) { self = .solution }
        else if ["完成了吗", "做完", "后来", "进展", "现在怎样"].contains(where: question.contains) { self = .status }
        else if ["变化", "相比", "不同"].contains(where: question.contains) { self = .change }
        else if ["做了哪些", "做了什么", "有哪些事情", "干了什么", "回顾", "总结"].contains(where: question.contains) { self = .overview }
        else { self = .recall }
    }
    public var guidance: String {
        switch self {
        case .overview: "按具体事情归并，覆盖查询日期；区分完成、推进、浏览。缺少记录的日期明确说明。"
        case .solution: "优先给出过去有结果支持的方法、适用条件与来源；不要把提议当成验证成功。"
        case .decision: "寻找当时的选项、取舍与最终决定；未记录的理由不要推测。"
        case .status: "按先后证据说明状态变化；没有后续证据就说尚未获知，不能推断已完成或停滞。"
        case .change: "比较不同时段的具体事实；只有单侧证据时说明无法比较。"
        case .recall: "直接回答问题，区分本人、对方与助手的话；不确定时说明证据边界。"
        }
    }
}

public struct MemoryEvidenceSelector: Sendable {
    public init() {}
    public func select(_ records: [CaptureRecord], question: String, limit: Int = 12) -> [CaptureRecord] {
        guard limit > 0 else { return [] }
        let intent = MemoryQuestionIntent(question: question)
        let terms = MatterMemoryEngine.subjectTerms(question)
        var hashes: Set<String> = []
        let unique = records.filter {
            let content = $0.ocrText.hasPrefix("记录时间：") ? $0.ocrText.split(separator: "\n").dropFirst().joined(separator: "\n") : $0.ocrText
            let key = content.lowercased().filter { !$0.isWhitespace }
            return hashes.insert(key).inserted
        }
        let ranked = unique.sorted { a, b in
            func relevance(_ item: CaptureRecord) -> Int {
                let text = item.ocrText + (item.windowTitle ?? "") + item.tags.joined()
                let matches = terms.filter { text.localizedCaseInsensitiveContains($0) }.count
                let result = ["验证通过", "已完成", "决定", "原因", "结论"].contains(where: text.contains)
                return matches * 4 + ((intent == .solution || intent == .decision) && result ? 1 : 0)
            }
            let left = relevance(a), right = relevance(b)
            return left == right ? a.createdAt > b.createdAt : left > right
        }
        // Reserve both ends of a relevant subject's timeline, then fill by relevance.
        var selected: [CaptureRecord] = []
        if [.status, .change, .decision].contains(intent), let anchor = ranked.first {
            let subject = MatterMemoryEngine.subjectTerms(anchor.windowTitle ?? anchor.summary ?? "")
            let related = ranked.filter { item in
                item.id == anchor.id || subject.filter { item.ocrText.localizedCaseInsensitiveContains($0) }.count >= 2
            }.sorted { $0.createdAt < $1.createdAt }
            if let first = related.first { selected.append(first) }
            if let last = related.last, last.id != selected.first?.id { selected.append(last) }
        }
        var ids = Set(selected.map(\.id))
        for record in ranked where selected.count < limit {
            if ids.insert(record.id).inserted { selected.append(record) }
        }
        return Array(selected.prefix(limit))
    }
}
