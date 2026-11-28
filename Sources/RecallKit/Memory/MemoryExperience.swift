import Foundation

public struct TopicTimelineEntry: Identifiable, Equatable, Sendable {
    public var id: UUID { event.id }
    public let event: MatterEvent
    public let headline: String
    public let body: String
    public var status: WorkEpisodeStatus { event.status }
    public var date: Date { event.date }
    public var nextAction: String? { event.nextAction }
    public var evidenceIDs: [UUID] { event.evidenceIDs }

    public init(event: MatterEvent) {
        self.event = event
        let raw = Self.strippingTopicPrefix(event.detail.trimmingCharacters(in: .whitespacesAndNewlines), topicTitle: event.title)
        if let explicit = event.headline?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            self.headline = explicit
            let stripped = Self.strippingPrefix(raw, prefix: explicit)
            let furtherStripped = Self.strippingTopicPrefix(stripped, topicTitle: event.title)
            if DailyKnowledgeEngine.topicKey(furtherStripped) == DailyKnowledgeEngine.topicKey(explicit) {
                self.body = ""
            } else {
                self.body = furtherStripped
            }
            return
        }
        let split = ReviewContentQuality.titleAndDetail(raw)
        if split.count == 2 {
            let head = split[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = split[1].trimmingCharacters(in: .whitespacesAndNewlines)
            self.headline = head
            self.body = DailyKnowledgeEngine.topicKey(head) == DailyKnowledgeEngine.topicKey(rest) ? "" : rest
            return
        }
        if raw.count <= 56 && !raw.contains("\n") {
            self.headline = raw
            self.body = ""
            return
        }
        if let endIndex = raw.firstIndex(where: { "。！？\n".contains($0) }) {
            let head = String(raw[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(raw[raw.index(after: endIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty, head.count <= 64 {
                self.headline = head
                self.body = rest
                return
            }
        }
        self.headline = ""
        self.body = raw
    }

    private static func strippingPrefix(_ text: String, prefix: String) -> String {
        if text == prefix { return "" }
        for sep in ["：", ":", " — ", " - "] where text.hasPrefix(prefix + sep) {
            return String(text.dropFirst((prefix + sep).count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func strippingTopicPrefix(_ text: String, topicTitle: String) -> String {
        let trimmedTopic = topicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else { return text }
        for sep in ["：", ":"] where text.hasPrefix(trimmedTopic + sep) {
            let remainder = String(text.dropFirst((trimmedTopic + sep).count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty { return remainder }
        }
        return text
    }
}

/// Reading a topic never requires a model call. Only saved, evidence-backed text is used here.
public struct TopicReading: Sendable {
    public enum NextActionOrigin: String, Sendable, Equatable {
        case userNote
        case record
    }

    public let overview: String
    /// 一句话摘要：最新主题小结的首句，否则最近一件具体事情的标题。
    public let headline: String
    /// 未生成跨日 AI 小结时，为首段最新单条事件补齐日期标题，保持旧调用兼容。
    public let latestDateTitle: String?
    /// 最后确认的事实日期，用于「11 月 27 日最后确认：…」日期锚点。
    public let lastConfirmedDate: Date
    /// 「现在」段落去重前缀后的可读正文：有最新跨日小结时用小结，否则用最后确认事项的去重事实。
    public let currentStatusSummary: String
    /// 「现在」段落对应的来源记录 ID。
    public let latestSourceIDs: [UUID]
    public let records: [MatterEvent]
    public let timelineEntries: [TopicTimelineEntry]
    public let points: [TopicReviewPoint]
    public let hasUpdatedSummary: Bool
    public let openNextAction: String?
    public let nextActionOrigin: NextActionOrigin?

    /// 按信息密度自适应折叠：已有跨日小结（且多于 1 条记录）或记录超过 3 条时默认折叠较早记录；无小结且 ≤ 3 条时直接展开。
    public var collapsesHistoryByDefault: Bool {
        (hasUpdatedSummary && timelineEntries.count > 1) || timelineEntries.count > 3
    }

    public static func fingerprint(_ file: MatterFile) -> String {
        CaptureUnderstandingEngine.digest(file.id + file.title + file.events.map {
            [$0.id.uuidString, $0.title, $0.detail, $0.status.rawValue, String(Int($0.date.timeIntervalSince1970)), $0.evidenceIDs.map(\.uuidString).sorted().joined()].joined(separator: "\u{1f}")
        }.joined(separator: "\n"))
    }

    public init(file: MatterFile, review: TopicModelReview? = nil) {
        var seen = Set<String>()
        let deduplicated = file.events.reversed().filter { event in
            let text = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && seen.insert(text).inserted
        }
        records = deduplicated
        timelineEntries = deduplicated.map(TopicTimelineEntry.init)

        let anchorEvent = file.latest
        lastConfirmedDate = anchorEvent.date

        let resolvedNext = Self.resolveEvidenceBackedNextAction(for: file)
        openNextAction = resolvedNext?.text
        nextActionOrigin = resolvedNext?.origin

        let usable = review.flatMap { $0.id == file.id ? $0 : nil }
        let current = usable.map { $0.inputFingerprint == Self.fingerprint(file) && Set(file.evidenceIDs).isSubset(of: Set($0.sourceVersions.keys)) } ?? false
        let resolvedOverview = current ? (usable?.overview.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? file.latest.detail) : file.latest.detail
        overview = resolvedOverview
        latestSourceIDs = current ? file.evidenceIDs : anchorEvent.evidenceIDs

        if current, let summaryOverview = usable?.overview.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            currentStatusSummary = summaryOverview
        } else {
            let entry = TopicTimelineEntry(event: anchorEvent)
            if !entry.headline.isEmpty && !entry.body.isEmpty {
                let punctuation = "。！？.!?;；".contains(entry.headline.last ?? " ") ? "" : RecallLocalization.both("，", ". ")
                currentStatusSummary = entry.headline + punctuation + entry.body
            } else if !entry.headline.isEmpty {
                currentStatusSummary = entry.headline
            } else {
                currentStatusSummary = entry.body
            }
        }

        let summarySentence = (current ? usable?.overview : nil)?
            .split(whereSeparator: { "。！？!?\n".contains($0) }).first.map(String.init)
        let eventHeadline = file.latest.headline?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        headline = String((summarySentence ?? eventHeadline ?? TopicTimelineEntry(event: file.latest).headline.nilIfEmpty ?? file.latest.detail).prefix(60))
        if let usable, current { points = usable.points }
        else {
            // Select actual milestones; no generated explanations or guessed decisions.
            var previous: WorkEpisodeStatus?
            var milestones: [MatterEvent] = []
            for event in file.events.dropLast() {
                if milestones.isEmpty || previous != event.status { milestones.append(event) }
                previous = event.status
            }
            points = milestones.suffix(3).filter { $0.detail != resolvedOverview }.map { event in
                TopicReviewPoint(title: RecallLocalization.both("记录于 ", "Recorded ") + event.date.formatted(date: .abbreviated, time: .omitted),
                    detail: event.detail, section: "progress", sourceIDs: event.evidenceIDs)
            }
        }
        hasUpdatedSummary = current
        latestDateTitle = current ? nil : (RecallLocalization.both("记录于 ", "Recorded ") + file.latest.date.formatted(date: .abbreviated, time: .omitted))
    }

    public func lastConfirmedAnchor(now: Date = .now, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: lastConfirmedDate)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let monthDay = lastConfirmedDate.formatted(.dateTime.month().day())
        if days <= 0 {
            return RecallLocalization.both("今天最后确认：", "Last confirmed today: ")
        } else if days == 1 {
            return RecallLocalization.both("\(monthDay)（昨天）最后确认：", "Last confirmed yesterday (\(monthDay)): ")
        } else {
            return RecallLocalization.both("\(monthDay)最后确认：", "Last confirmed \(monthDay): ")
        }
    }

    public func suggestedPrompts(for file: MatterFile) -> [String] {
        var prompts: [String] = []
        if file.latest.status == .blocked {
            prompts.append(RecallLocalization.both("卡住的具体原因和上下文是什么？", "What caused the blocker and what is the context?"))
        }
        let combined = file.latest.detail + " " + file.title
        if combined.contains("合入") || combined.contains("PR") || combined.contains("提交") || combined.contains("改动") {
            prompts.append(RecallLocalization.both("这次改动包含哪些具体内容？", "What specific changes were included?"))
        }
        if timelineEntries.count >= 2 {
            prompts.append(RecallLocalization.both("按时间梳理这件事的关键决定与变化", "Trace key decisions and changes over time"))
        } else {
            prompts.append(RecallLocalization.both("当时的原始记录里还有哪些细节？", "What other details are in the original records?"))
        }
        if openNextAction != nil || file.latest.status.isOpenMatter {
            prompts.append(RecallLocalization.both("围绕接下来要做的事，之前有哪些相关依据？", "What prior context relates to the next step?"))
        }
        return Array(prompts.prefix(3))
    }

    /// Only surface a "next step" when backed by user notes or explicit open action evidence; never invent filler.
    private static func resolveEvidenceBackedNextAction(for file: MatterFile) -> (text: String, origin: NextActionOrigin)? {
        guard file.latest.status.isOpenMatter else { return nil }
        let boilerplate = ["待后续观察", "后续持续关注", "待观察复盘", "后续跟进观察"]
        func cleanCandidate(_ raw: String?) -> String? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            if boilerplate.contains(where: { trimmed.contains($0) }) && trimmed.count <= 16 { return nil }
            return trimmed
        }
        if let explicit = cleanCandidate(file.latest.nextAction) {
            let fromUser = file.latest.quotes.isEmpty && file.latest.headline == nil
            return (explicit, fromUser ? .userNote : .record)
        }
        if let extracted = cleanCandidate(ManualMatterNote.extractedNextAction(from: file.latest.detail)) {
            let fromUser = file.latest.quotes.isEmpty && file.latest.headline == nil
            return (extracted, fromUser ? .userNote : .record)
        }
        if let resumed = cleanCandidate(file.resumeNextAction) {
            return (resumed, .record)
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Explicit user commands only. Ambiguous names are presented for clarification, never mass-edited.
public struct MemoryManagementCommand: Sendable {
    public enum Action: Sendable { case forget, pause, resume, replace(String) }
    public var action: Action
    public var target: String
    public static func parse(_ input: String) -> MemoryManagementCommand? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("请") { text = String(text.dropFirst()) }
        for (prefix, action) in [("不再记住", Action.forget), ("忘记", .forget), ("暂停参考", .pause), ("恢复参考", .resume)] where text.hasPrefix(prefix) {
            let value = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "：:，, \"“”‘’。"))
            guard !value.isEmpty, !value.contains("？"), !value.contains("?"), value.count <= 800 else { return nil }
            return Self(action: action, target: value)
        }
        for prefix in ["修改记忆：", "修改记忆:", "更新记忆：", "更新记忆:"] where text.hasPrefix(prefix) {
            let body = String(text.dropFirst(prefix.count))
            let parts = body.components(separatedBy: "改为")
            guard parts.count == 2 else { return nil }
            let values = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"“”‘’")) }
            guard values.allSatisfy({ !$0.isEmpty && $0.count <= 800 }) else { return nil }
            return Self(action: .replace(values[1]), target: values[0])
        }
        return nil
    }
    public func matches(in state: RecallState) -> [MemoryClaim] {
        let values = state.memoryKnowledge.claims.filter { MemoryLibraryCategory.all.includes($0.kind) && $0.usable() }
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = values.filter { $0.id.uuidString == target || $0.content == target || $0.title == target }
        if !exact.isEmpty { return exact }
        return values.filter { $0.content.localizedCaseInsensitiveContains(target) || $0.title.localizedCaseInsensitiveContains(target) }
    }
}

public enum PersonalMemoryContext {
    /// Includes explicit memory records, which are intentionally excluded from raw factual search.
    public static func sourceRecords(in state: RecallState) -> [CaptureRecord] {
        let invalid = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        return state.captures.filter {
            !invalid.contains($0.id) && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "")
                && ($0.isMemoryEvidenceArchive != true || $0.memoryDirective != nil) && $0.eventTemplate != .dailyReview
        }
    }
    /// Inferred observations shape conversational answers only; generated reviews stay free of them.
    public static func text(in state: RecallState, question: String, topicIDs: Set<String> = [], conversationID: UUID? = nil, includesObservations: Bool = false) -> String {
        let allowed = Set(sourceRecords(in: state).filter { source in state.rules.first { $0.template == source.eventTemplate }?.participatesInChat ?? true }.map(\.id))
        let claims = state.memoryKnowledge.claims.filter {
            $0.kind.isPersonal && $0.usable() && state.memoryKnowledgeSettings.references($0)
                && !$0.sourceIDs.isEmpty && Set($0.sourceIDs).isSubset(of: allowed)
        }
        let explicit = MemoryRetrievalEngine().preferenceContext(question: question, claims: claims, conversationID: conversationID, entities: topicIDs) ?? ""
        let inferred = includesObservations ? PersonaPersonalization.text(in: state) : ""
        return [explicit, inferred].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
