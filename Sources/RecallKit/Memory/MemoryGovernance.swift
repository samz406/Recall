import Foundation

public enum MemoryDeletionReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case duplicate
    case inaccurate
    case unimportant
    case sensitive
    case noLongerNeeded
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .duplicate: "重复内容"
        case .inaccurate: "内容不准确"
        case .unimportant: "对我不重要"
        case .sensitive: "包含敏感信息"
        case .noLongerNeeded: "不再需要"
        case .other: "其他原因"
        }
    }
}

public struct MemorySuppressionRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var phrase: String
    public var normalizedPhrase: String
    public var sourceBundleIdentifier: String?
    public var reason: MemoryDeletionReason
    public var createdAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        phrase: String,
        sourceBundleIdentifier: String? = nil,
        reason: MemoryDeletionReason,
        createdAt: Date = .now,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.phrase = phrase
        self.normalizedPhrase = Self.normalize(phrase)
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.reason = reason
        self.createdAt = createdAt
        self.isEnabled = isEnabled
    }

    public func matches(text: String, sourceBundleIdentifier: String?) -> Bool {
        guard isEnabled else { return false }
        if let expectedBundle = self.sourceBundleIdentifier,
           expectedBundle != sourceBundleIdentifier { return false }
        let normalizedText = Self.normalize(text)
        guard normalizedPhrase.count >= 6, normalizedText.count >= 6 else { return false }
        return normalizedText.contains(normalizedPhrase) || normalizedPhrase.contains(normalizedText)
    }

    public static func phrase(for capture: CaptureRecord) -> String? {
        let candidate = (capture.summary ?? capture.ocrText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 6 else { return nil }
        return String(candidate.prefix(120))
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

public struct MemoryDeletionImpact: Codable, Hashable, Sendable {
    public var captureCount: Int
    public var screenshotCount: Int
    public var summaryCount: Int
    public var summaryItemCount: Int
    public var reminderCount: Int
    public var conversationCount: Int
    public var intelligenceCount: Int
    public var affectedDays: [Date]

    public init(
        captureCount: Int = 0,
        screenshotCount: Int = 0,
        summaryCount: Int = 0,
        summaryItemCount: Int = 0,
        reminderCount: Int = 0,
        conversationCount: Int = 0,
        intelligenceCount: Int = 0,
        affectedDays: [Date] = []
    ) {
        self.captureCount = captureCount
        self.screenshotCount = screenshotCount
        self.summaryCount = summaryCount
        self.summaryItemCount = summaryItemCount
        self.reminderCount = reminderCount
        self.conversationCount = conversationCount
        self.intelligenceCount = intelligenceCount
        self.affectedDays = affectedDays
    }

    public var totalAffectedCount: Int {
        captureCount + screenshotCount + summaryCount + summaryItemCount + reminderCount + conversationCount + intelligenceCount
    }
}

/// 可恢复删除的完整本地快照。恢复期限结束后，截图文件和这份快照一起永久清理。
public struct RecentlyDeletedMemory: Identifiable, Codable, Sendable {
    public var id: UUID
    public var label: String
    public var reason: MemoryDeletionReason
    public var deletedAt: Date
    public var expiresAt: Date
    public var captures: [CaptureRecord]
    public var summaries: [DailySummary]
    public var messages: [ConversationMessage]
    public var reminders: [ReminderCandidate]
    public var episodes: [WorkEpisode]
    public var projects: [ProjectState]
    public var userMemories: [UserMemory]
    public var insights: [PersonalInsight]
    public var insightFeedback: [InsightFeedback]
    public var routines: [LearnedRoutine]
    public var checkpointHashes: [String: String]
    public var affectedDays: [Date]
    public var previousConversationSummary: String?
    public var previousConversationSummaryCoveredMessageCount: Int?
    public var addedSuppressionRuleIDs: [UUID]

    public init(
        id: UUID = UUID(),
        label: String,
        reason: MemoryDeletionReason,
        deletedAt: Date = .now,
        expiresAt: Date,
        captures: [CaptureRecord] = [],
        summaries: [DailySummary] = [],
        messages: [ConversationMessage] = [],
        reminders: [ReminderCandidate] = [],
        episodes: [WorkEpisode] = [],
        projects: [ProjectState] = [],
        userMemories: [UserMemory] = [],
        insights: [PersonalInsight] = [],
        insightFeedback: [InsightFeedback] = [],
        routines: [LearnedRoutine] = [],
        checkpointHashes: [String: String] = [:],
        affectedDays: [Date] = [],
        previousConversationSummary: String? = nil,
        previousConversationSummaryCoveredMessageCount: Int? = nil,
        addedSuppressionRuleIDs: [UUID] = []
    ) {
        self.id = id
        self.label = label
        self.reason = reason
        self.deletedAt = deletedAt
        self.expiresAt = expiresAt
        self.captures = captures
        self.summaries = summaries
        self.messages = messages
        self.reminders = reminders
        self.episodes = episodes
        self.projects = projects
        self.userMemories = userMemories
        self.insights = insights
        self.insightFeedback = insightFeedback
        self.routines = routines
        self.checkpointHashes = checkpointHashes
        self.affectedDays = affectedDays
        self.previousConversationSummary = previousConversationSummary
        self.previousConversationSummaryCoveredMessageCount = previousConversationSummaryCoveredMessageCount
        self.addedSuppressionRuleIDs = addedSuppressionRuleIDs
    }

    public var screenshotPaths: [String] { captures.compactMap(\.imageRelativePath) }
}

public enum MemoryGovernance {
    public static let retentionDays = 7

    public static func impact(of captureIDs: Set<UUID>, in state: RecallState, calendar: Calendar = .current) -> MemoryDeletionImpact {
        let captures = state.captures.filter { captureIDs.contains($0.id) }
        let summaries = state.dailySummaries.filter { !$0.sourceCaptureIDs.filter(captureIDs.contains).isEmpty }
        let summaryItems = summaries.flatMap(\.items).filter { item in
            !item.evidenceIDs.filter(captureIDs.contains).isEmpty
        }
        let reminders = state.reminders.filter { reminder in
            reminder.origin != .manual && !reminder.sourceCaptureIDs.filter(captureIDs.contains).isEmpty
        }
        let messages = state.messages.filter { message in
            message.role == .assistant && !message.citations.filter(captureIDs.contains).isEmpty
        }
        let episodes = state.episodes.filter { !$0.evidenceIDs.filter(captureIDs.contains).isEmpty }
        let projects = state.projects.filter { !$0.evidenceIDs.filter(captureIDs.contains).isEmpty }
        let memories = state.userMemories.filter { !$0.evidenceIDs.filter(captureIDs.contains).isEmpty }
        let insights = state.insights.filter { !$0.evidenceIDs.filter(captureIDs.contains).isEmpty }
        let routines = state.learnedRoutines.filter { !$0.evidenceIDs.filter(captureIDs.contains).isEmpty }
        let days = Set(captures.map { calendar.startOfDay(for: $0.createdAt) })
            .union(Set(summaries.map { calendar.startOfDay(for: $0.day) }))
        return MemoryDeletionImpact(
            captureCount: captures.count,
            screenshotCount: captures.filter { $0.imageRelativePath != nil }.count,
            summaryCount: summaries.count,
            summaryItemCount: summaryItems.count,
            reminderCount: reminders.count,
            conversationCount: messages.count,
            intelligenceCount: episodes.count + projects.count + memories.count + insights.count + routines.count,
            affectedDays: days.sorted()
        )
    }
}
