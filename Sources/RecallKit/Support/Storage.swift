import Foundation

public enum RecallStorageError: LocalizedError {
    case missingApplicationSupportDirectory

    public var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory: "无法定位应用支持目录。"
        }
    }
}

public struct RecallStorage: Sendable {
    public let rootURL: URL
    public let screenshotsURL: URL
    public let stateURL: URL
    public let intelligenceDatabaseURL: URL

    public init(fileManager: FileManager = .default) throws {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecallStorageError.missingApplicationSupportDirectory
        }
        rootURL = appSupport.appendingPathComponent("Recall", isDirectory: true)
        screenshotsURL = rootURL.appendingPathComponent("Screenshots", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("recall-state.json")
        intelligenceDatabaseURL = rootURL.appendingPathComponent("recall-intelligence.sqlite")
        try fileManager.createDirectory(at: screenshotsURL, withIntermediateDirectories: true)
    }

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        screenshotsURL = rootURL.appendingPathComponent("Screenshots", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("recall-state.json")
        intelligenceDatabaseURL = rootURL.appendingPathComponent("recall-intelligence.sqlite")
        try fileManager.createDirectory(at: screenshotsURL, withIntermediateDirectories: true)
    }

    public func saveScreenshot(_ data: Data, captureID: UUID, fileManager: FileManager = .default) throws -> String {
        let filename = "\(captureID.uuidString.lowercased()).png"
        let destination = screenshotsURL.appendingPathComponent(filename)
        try data.write(to: destination, options: .atomic)
        return "Screenshots/\(filename)"
    }

    public func screenshotURL(relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    public func deleteScreenshot(relativePath: String, fileManager: FileManager = .default) throws {
        let url = screenshotURL(relativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

public struct RecallState: Codable, Sendable {
    public var rules: [EventRule]
    public var captures: [CaptureRecord]
    public var messages: [ConversationMessage]
    public var reminders: [ReminderCandidate]
    public var reminderDiscoveryCheckpoint: ReminderDiscoveryCheckpoint
    public var reminderLearningProfile: ReminderLearningProfile
    public var dailySummaries: [DailySummary]
    public var dailySummarySettings: DailySummarySettings
    public var privacy: PrivacySettings
    public var llmConfiguration: LLMConfiguration
    public var conversationSummary: String?
    public var conversationSummaryCoveredMessageCount: Int?
    public var episodes: [WorkEpisode]
    public var projects: [ProjectState]
    public var userMemories: [UserMemory]
    public var insights: [PersonalInsight]
    public var insightFeedback: [InsightFeedback]
    public var learnedRoutines: [LearnedRoutine]

    public init(
        rules: [EventRule] = EventRule.defaults(),
        captures: [CaptureRecord] = [],
        messages: [ConversationMessage] = [],
        reminders: [ReminderCandidate] = [],
        reminderDiscoveryCheckpoint: ReminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint(),
        reminderLearningProfile: ReminderLearningProfile = ReminderLearningProfile(),
        dailySummaries: [DailySummary] = [],
        dailySummarySettings: DailySummarySettings = DailySummarySettings(),
        privacy: PrivacySettings = PrivacySettings(),
        llmConfiguration: LLMConfiguration = LLMConfiguration(),
        conversationSummary: String? = nil,
        conversationSummaryCoveredMessageCount: Int? = 0,
        episodes: [WorkEpisode] = [],
        projects: [ProjectState] = [],
        userMemories: [UserMemory] = [],
        insights: [PersonalInsight] = [],
        insightFeedback: [InsightFeedback] = [],
        learnedRoutines: [LearnedRoutine] = []
    ) {
        self.rules = rules
        self.captures = captures
        self.messages = messages
        self.reminders = reminders
        self.reminderDiscoveryCheckpoint = reminderDiscoveryCheckpoint
        self.reminderLearningProfile = reminderLearningProfile
        self.dailySummaries = dailySummaries
        self.dailySummarySettings = dailySummarySettings
        self.privacy = privacy
        self.llmConfiguration = llmConfiguration
        self.conversationSummary = conversationSummary
        self.conversationSummaryCoveredMessageCount = conversationSummaryCoveredMessageCount
        self.episodes = episodes
        self.projects = projects
        self.userMemories = userMemories
        self.insights = insights
        self.insightFeedback = insightFeedback
        self.learnedRoutines = learnedRoutines
    }

    private enum CodingKeys: String, CodingKey {
        case rules, captures, messages, reminders, reminderDiscoveryCheckpoint, reminderLearningProfile, dailySummaries, dailySummarySettings
        case privacy, llmConfiguration, conversationSummary, conversationSummaryCoveredMessageCount
        case episodes, projects, userMemories, insights, insightFeedback, learnedRoutines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([EventRule].self, forKey: .rules) ?? EventRule.defaults()
        captures = try container.decodeIfPresent([CaptureRecord].self, forKey: .captures) ?? []
        messages = try container.decodeIfPresent([ConversationMessage].self, forKey: .messages) ?? []
        reminders = try container.decodeIfPresent([ReminderCandidate].self, forKey: .reminders) ?? []
        reminderDiscoveryCheckpoint = try container.decodeIfPresent(ReminderDiscoveryCheckpoint.self, forKey: .reminderDiscoveryCheckpoint) ?? ReminderDiscoveryCheckpoint()
        reminderLearningProfile = try container.decodeIfPresent(ReminderLearningProfile.self, forKey: .reminderLearningProfile) ?? ReminderLearningProfile()
        dailySummaries = try container.decodeIfPresent([DailySummary].self, forKey: .dailySummaries) ?? []
        dailySummarySettings = try container.decodeIfPresent(DailySummarySettings.self, forKey: .dailySummarySettings) ?? DailySummarySettings()
        privacy = try container.decodeIfPresent(PrivacySettings.self, forKey: .privacy) ?? PrivacySettings()
        llmConfiguration = try container.decodeIfPresent(LLMConfiguration.self, forKey: .llmConfiguration) ?? LLMConfiguration()
        conversationSummary = try container.decodeIfPresent(String.self, forKey: .conversationSummary)
        conversationSummaryCoveredMessageCount = try container.decodeIfPresent(Int.self, forKey: .conversationSummaryCoveredMessageCount) ?? 0
        episodes = try container.decodeIfPresent([WorkEpisode].self, forKey: .episodes) ?? []
        projects = try container.decodeIfPresent([ProjectState].self, forKey: .projects) ?? []
        userMemories = try container.decodeIfPresent([UserMemory].self, forKey: .userMemories) ?? []
        insights = try container.decodeIfPresent([PersonalInsight].self, forKey: .insights) ?? []
        insightFeedback = try container.decodeIfPresent([InsightFeedback].self, forKey: .insightFeedback) ?? []
        learnedRoutines = try container.decodeIfPresent([LearnedRoutine].self, forKey: .learnedRoutines) ?? []
    }
}

public actor FileMemoryStore {
    private let storage: RecallStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: RecallState
    private let intelligenceIndex: SQLiteIntelligenceIndex?

    public init() throws {
        try self.init(storage: RecallStorage())
    }

    public init(storage: RecallStorage) throws {
        self.storage = storage
        intelligenceIndex = try? SQLiteIntelligenceIndex(databaseURL: storage.intelligenceDatabaseURL)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if FileManager.default.fileExists(atPath: storage.stateURL.path) {
            let data = try Data(contentsOf: storage.stateURL)
            var restoredState = try decoder.decode(RecallState.self, from: data)
            let existingTemplates = Set(restoredState.rules.map(\.template))
            let missingRules = EventRule.defaults().filter { !existingTemplates.contains($0.template) }
            if !missingRules.isEmpty {
                restoredState.rules.append(contentsOf: missingRules)
            }
            // 仅迁移完全等于旧版默认值的提醒范围；用户手动调整过的规则保持不变。
            let legacyReminderTemplates: Set<CaptureEventTemplate> = [.taskCommitment, .dailyReview]
            let currentReminderTemplates = Set(restoredState.rules.filter(\.participatesInReminders).map(\.template))
            if currentReminderTemplates == legacyReminderTemplates {
                let nextDefaults = Dictionary(uniqueKeysWithValues: EventRule.defaults().map { ($0.template, $0.participatesInReminders) })
                restoredState.rules = restoredState.rules.map { rule in
                    var updated = rule
                    updated.participatesInReminders = nextDefaults[rule.template] ?? rule.participatesInReminders
                    return updated
                }
            }
            try Self.write(restoredState, encoder: encoder, to: storage.stateURL)
            state = restoredState
        } else {
            state = RecallState()
            try Self.write(state, encoder: encoder, to: storage.stateURL)
        }
        try? intelligenceIndex?.replace(with: state)
    }

    public func snapshot() -> RecallState { state }

    public func isIntelligenceIndexAvailable() -> Bool { intelligenceIndex != nil }

    public func indexedCaptureIDs(matching query: String, limit: Int = 12) -> [UUID] {
        (try? intelligenceIndex?.searchCaptureIDs(matching: query, limit: limit)) ?? []
    }

    public func updateRules(_ rules: [EventRule]) throws {
        state.rules = rules
        try persist()
    }

    public func updatePrivacy(_ privacy: PrivacySettings) throws {
        state.privacy = privacy
        try persist()
    }

    public func updateLLMConfiguration(_ configuration: LLMConfiguration) throws {
        state.llmConfiguration = configuration
        try persist()
    }

    public func updateDailySummarySettings(_ settings: DailySummarySettings) throws {
        state.dailySummarySettings = settings
        try persist()
    }

    public func upsertDailySummary(_ summary: DailySummary) throws {
        state.dailySummaries.removeAll { Calendar.current.isDate($0.day, inSameDayAs: summary.day) }
        state.dailySummaries.append(summary)
        state.dailySummaries.sort { $0.day > $1.day }
        try persist()
    }

    public func applyIntelligence(_ consolidation: IntelligenceConsolidation, for day: Date) throws {
        applyIntelligenceState(consolidation, for: day)
        try persist()
    }

    public func commitDailySummary(_ summary: DailySummary, consolidation: IntelligenceConsolidation) throws {
        state.dailySummaries.removeAll { Calendar.current.isDate($0.day, inSameDayAs: summary.day) }
        state.dailySummaries.append(summary)
        state.dailySummaries.sort { $0.day > $1.day }
        applyIntelligenceState(consolidation, for: summary.day)
        try persist()
    }

    private func applyIntelligenceState(_ consolidation: IntelligenceConsolidation, for day: Date) {
        let calendar = Calendar.current
        state.episodes.removeAll { calendar.isDate($0.day, inSameDayAs: day) }
        state.episodes.append(contentsOf: consolidation.episodes)
        state.episodes.sort { $0.startedAt > $1.startedAt }
        state.projects = consolidation.projectStates
        state.userMemories = consolidation.memories
        state.insights.removeAll { calendar.isDate($0.day, inSameDayAs: day) }
        state.insights.append(contentsOf: consolidation.insights)
        state.insights.sort { $0.createdAt > $1.createdAt }
        state.learnedRoutines = consolidation.routines
    }

    public func reviewInsight(id: UUID, rating: InsightFeedbackRating) throws {
        guard let insight = state.insights.first(where: { $0.id == id }) else { return }
        state.insightFeedback.removeAll { $0.insightID == id }
        state.insightFeedback.append(InsightFeedback(insightID: id, insightKind: insight.kind, rating: rating))
        try persist()
    }

    public func reviewUserMemory(id: UUID, status: MemoryReviewStatus) throws {
        guard let index = state.userMemories.firstIndex(where: { $0.id == id }) else { return }
        state.userMemories[index].status = status
        state.userMemories[index].updatedAt = .now
        try persist()
    }

    public func updateRoutine(id: UUID, status: LearnedRoutineStatus) throws {
        guard let index = state.learnedRoutines.firstIndex(where: { $0.id == id }) else { return }
        state.learnedRoutines[index].status = status
        state.learnedRoutines[index].updatedAt = .now
        try persist()
    }

    public func deleteDailySummary(id: UUID) throws {
        state.dailySummaries.removeAll { $0.id == id }
        try persist()
    }

    public func clearDailySummaries() throws {
        state.dailySummaries = []
        try persist()
    }

    public func clearPersonalIntelligence() throws {
        state.episodes = []
        state.projects = []
        state.userMemories = []
        state.insights = []
        state.insightFeedback = []
        state.learnedRoutines = []
        try persist()
    }

    public func updateConversationSummary(_ summary: String?, coveredMessageCount: Int) throws {
        state.conversationSummary = summary
        state.conversationSummaryCoveredMessageCount = coveredMessageCount
        try persist()
    }

    public func addCapture(_ capture: CaptureRecord) throws {
        state.captures.insert(capture, at: 0)
        try persist()
    }

    public func deleteCapture(id: UUID) throws -> CaptureRecord? {
        guard let index = state.captures.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = state.captures.remove(at: index)
        // 总结正文可能包含这条记录的内容；删除来源时一并删除受影响总结，避免残留可识别文本。
        state.dailySummaries.removeAll { $0.sourceCaptureIDs.contains(id) }
        state.episodes.removeAll { $0.evidenceIDs.contains(id) }
        state.insights.removeAll { $0.evidenceIDs.contains(id) }
        state.userMemories.removeAll { $0.evidenceIDs.contains(id) }
        state.learnedRoutines.removeAll { $0.evidenceIDs.contains(id) }
        // 提醒正文同样可能包含来源记录中的可识别文本。删除来源时删除其派生提醒，
        // 由用户手动创建且没有来源关联的提醒不受影响。
        state.reminders.removeAll { $0.sourceCaptureIDs.contains(id) }
        state.reminderDiscoveryCheckpoint.processedCaptureHashes.removeValue(forKey: id.uuidString)
        state.projects = state.projects.compactMap { project in
            var updated = project
            updated.evidenceIDs.removeAll { $0 == id }
            return updated.evidenceIDs.isEmpty ? nil : updated
        }
        try persist()
        return removed
    }

    public func addMessage(_ message: ConversationMessage) throws {
        state.messages.append(message)
        try persist()
    }

    public func replaceReminders(_ reminders: [ReminderCandidate]) throws {
        state.reminders = reminders
        try persist()
    }

    public func commitReminderDiscovery(
        reminders: [ReminderCandidate],
        checkpoint: ReminderDiscoveryCheckpoint
    ) throws {
        state.reminders = reminders
        state.reminderDiscoveryCheckpoint = checkpoint
        try persist()
    }

    public func updateReminder(_ reminder: ReminderCandidate) throws {
        guard let index = state.reminders.firstIndex(where: { $0.id == reminder.id }) else {
            state.reminders.insert(reminder, at: 0)
            try persist()
            return
        }
        state.reminders[index] = reminder
        try persist()
    }

    /// 将提醒状态与用户反馈一次写入，避免只保存了其中一部分。
    public func updateReminder(
        _ reminder: ReminderCandidate,
        learningProfile: ReminderLearningProfile
    ) throws {
        if let index = state.reminders.firstIndex(where: { $0.id == reminder.id }) {
            state.reminders[index] = reminder
        } else {
            state.reminders.insert(reminder, at: 0)
        }
        state.reminderLearningProfile = learningProfile
        try persist()
    }

    public func removeReminders(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        state.reminders.removeAll { ids.contains($0.id) }
        try persist()
    }

    /// 批量忽略尚未被用户确认的候选提醒；已安排的系统通知不会受到影响。
    @discardableResult
    public func dismissAllProposedReminders() throws -> Int {
        var dismissedCount = 0
        var learningProfile = state.reminderLearningProfile
        state.reminders = state.reminders.map { reminder in
            guard reminder.status == .proposed else { return reminder }
            var updated = reminder
            updated.status = .dismissed
            updated.dismissedUntil = Calendar.current.date(byAdding: .day, value: 30, to: .now)
            updated.updatedAt = .now
            let semanticKey = reminder.semanticKey.isEmpty
                ? String(reminder.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).filter { $0.isLetter || $0.isNumber })
                : reminder.semanticKey
            learningProfile.record(.dismissed, semanticKey: semanticKey)
            dismissedCount += 1
            return updated
        }
        guard dismissedCount > 0 else { return 0 }
        state.reminderLearningProfile = learningProfile
        try persist()
        return dismissedCount
    }

    public func clearReminderData() throws {
        state.reminders = []
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
        state.reminderLearningProfile = ReminderLearningProfile()
        try persist()
    }

    public func hasRecentHash(_ hash: String, within seconds: TimeInterval = 12, now: Date = .now) -> Bool {
        state.captures.contains { record in
            record.contentHash == hash && now.timeIntervalSince(record.createdAt) <= seconds
        }
    }

    public func prune(now: Date = .now) throws -> [String] {
        var pathsToDelete: [String] = []
        let retained = state.captures.filter { record in
            guard let rule = state.rules.first(where: { $0.template == record.eventTemplate }) else { return true }
            if let imagePath = record.imageRelativePath,
               now.timeIntervalSince(record.createdAt) > Double(rule.retainImageDays) * 86_400 {
                pathsToDelete.append(imagePath)
            }
            return now.timeIntervalSince(record.createdAt) <= Double(rule.retainTextDays) * 86_400
        }
        state.captures = retained
        try persist()
        return pathsToDelete
    }

    private func persist() throws {
        try Self.write(state, encoder: encoder, to: storage.stateURL)
        try intelligenceIndex?.replace(with: state)
    }

    private static func write(_ state: RecallState, encoder: JSONEncoder, to url: URL) throws {
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }
}
