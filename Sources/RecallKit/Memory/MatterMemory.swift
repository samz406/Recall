import Foundation

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
    public var date: Date { eventAt ?? recordedAt }
    public init(id: UUID, title: String, detail: String, recordedAt: Date, eventAt: Date? = nil, status: WorkEpisodeStatus, evidenceIDs: [UUID]) {
        self.id = id; self.title = title; self.detail = detail; self.recordedAt = recordedAt
        self.eventAt = eventAt; self.status = status; self.evidenceIDs = evidenceIDs
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
    public var resumeText: String {
        latest.status == .completed ? "最近记录为已完成；可回看过程与结果。" : "上次记录：\(latest.detail)\n此后是否完成，尚未获知。"
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
        // Rebuild missing days locally; no model calls, no capture or external effects.
        let existingDays = Set(safe.episodes.map { calendar.startOfDay(for: $0.day) })
        let missing = Dictionary(grouping: safe.captures) { calendar.startOfDay(for: $0.createdAt) }
            .filter { !existingDays.contains($0.key) }
        let rebuilt = missing.flatMap { PersonalIntelligenceEngine().buildEpisodes(day: $0.key, records: $0.value, calendar: calendar) }
        var groups: [String: [MatterEvent]] = [:]
        var names: [String: String] = [:]
        var seen: Set<String> = []
        for episode in safe.episodes + rebuilt {
            let ids = episode.evidenceIDs.filter(available.contains)
            guard !ids.isEmpty, !episode.projectKey.hasPrefix("app:"), !episode.projectKey.hasPrefix("unresolved:") else { continue }
            var key = episode.projectKey
            var name = episode.projectName
            let corrections = state.matterCorrections.filter { !Set($0.evidenceIDs).isDisjoint(with: ids) }
            if let separated = corrections.last(where: { $0.kind == .separate }), !separated.text.isEmpty {
                key = "user:" + normalized(separated.text)
                name = separated.text
            }
            guard name.count >= 3, name.count <= 100 else { continue }
            let detail = episode.outcome ?? episode.action
            guard detail.count >= 6 else { continue }
            let signature = key + ":" + normalized(detail)
            guard seen.insert(signature).inserted else { continue }
            let eventDate = corrections.last(where: { $0.kind == .eventDate })?.eventAt
            let recordedAt = ids.compactMap { captured[$0]?.createdAt }.max() ?? episode.endedAt
            let completed = corrections.contains { $0.kind == .completed }
            let event = MatterEvent(id: ids.sorted { $0.uuidString < $1.uuidString }[0], title: name,
                detail: completed ? "用户已标记完成：\(name)" : detail,
                recordedAt: recordedAt, eventAt: eventDate,
                status: completed ? .completed : episode.status, evidenceIDs: ids)
            groups[key, default: []].append(event)
            names[key] = name
        }
        return groups.map { key, events in
            MatterFile(id: key, title: names[key] ?? key, events: events.sorted {
                $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
            })
        }.sorted { $0.latest.date == $1.latest.date ? $0.id < $1.id : $0.latest.date > $1.latest.date }
    }

    public func weeklyReview(files: [MatterFile], endingAt end: Date = .now, calendar: Calendar = .current) -> [MatterReview] {
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: end)) ?? end
        return files.compactMap { file in
            let changes = file.events.filter { $0.date >= start && $0.date <= end }
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

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
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
            result.conversationSummary = nil
            result.conversationSummaryCoveredMessageCount = 0
        }
        result.captures.removeAll { invalid.contains($0.id) }
        result.episodes.removeAll { !Set($0.evidenceIDs).isDisjoint(with: invalid) }
        result.projects.removeAll { !Set($0.evidenceIDs).isDisjoint(with: touched) }
        result.userMemories.removeAll { !Set($0.evidenceIDs).isDisjoint(with: touched) }
        result.insights.removeAll { !Set($0.evidenceIDs).isDisjoint(with: touched) }
        result.dailySummaries.removeAll { !Set($0.sourceCaptureIDs).isDisjoint(with: touched) }
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
