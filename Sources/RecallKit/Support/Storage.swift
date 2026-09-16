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
    public let recentlyDeletedScreenshotsURL: URL
    public let stateURL: URL
    public let intelligenceDatabaseURL: URL

    public init(fileManager: FileManager = .default) throws {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecallStorageError.missingApplicationSupportDirectory
        }
        rootURL = appSupport.appendingPathComponent("Recall", isDirectory: true)
        screenshotsURL = rootURL.appendingPathComponent("Screenshots", isDirectory: true)
        recentlyDeletedScreenshotsURL = rootURL.appendingPathComponent("Recently Deleted/Screenshots", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("recall-state.json")
        intelligenceDatabaseURL = rootURL.appendingPathComponent("recall-intelligence.sqlite")
        try fileManager.createDirectory(at: screenshotsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recentlyDeletedScreenshotsURL, withIntermediateDirectories: true)
    }

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        screenshotsURL = rootURL.appendingPathComponent("Screenshots", isDirectory: true)
        recentlyDeletedScreenshotsURL = rootURL.appendingPathComponent("Recently Deleted/Screenshots", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("recall-state.json")
        intelligenceDatabaseURL = rootURL.appendingPathComponent("recall-intelligence.sqlite")
        try fileManager.createDirectory(at: screenshotsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recentlyDeletedScreenshotsURL, withIntermediateDirectories: true)
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

    public func moveScreenshotToRecentlyDeleted(relativePath: String, fileManager: FileManager = .default) throws {
        let source = screenshotURL(relativePath: relativePath)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let destination = recentlyDeletedScreenshotsURL.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: source, to: destination)
    }

    public func restoreScreenshot(relativePath: String, fileManager: FileManager = .default) throws {
        let destination = screenshotURL(relativePath: relativePath)
        let source = recentlyDeletedScreenshotsURL.appendingPathComponent(destination.lastPathComponent)
        guard fileManager.fileExists(atPath: source.path) else { return }
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: source, to: destination)
    }

    public func permanentlyDeleteRecentlyDeletedScreenshot(relativePath: String, fileManager: FileManager = .default) throws {
        let filename = screenshotURL(relativePath: relativePath).lastPathComponent
        let url = recentlyDeletedScreenshotsURL.appendingPathComponent(filename)
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
    public var recentlyDeletedMemories: [RecentlyDeletedMemory]
    public var memorySuppressionRules: [MemorySuppressionRule]

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
        learnedRoutines: [LearnedRoutine] = [],
        recentlyDeletedMemories: [RecentlyDeletedMemory] = [],
        memorySuppressionRules: [MemorySuppressionRule] = []
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
        self.recentlyDeletedMemories = recentlyDeletedMemories
        self.memorySuppressionRules = memorySuppressionRules
    }

    private enum CodingKeys: String, CodingKey {
        case rules, captures, messages, reminders, reminderDiscoveryCheckpoint, reminderLearningProfile, dailySummaries, dailySummarySettings
        case privacy, llmConfiguration, conversationSummary, conversationSummaryCoveredMessageCount
        case episodes, projects, userMemories, insights, insightFeedback, learnedRoutines
        case recentlyDeletedMemories, memorySuppressionRules
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
        recentlyDeletedMemories = try container.decodeIfPresent([RecentlyDeletedMemory].self, forKey: .recentlyDeletedMemories) ?? []
        memorySuppressionRules = try container.decodeIfPresent([MemorySuppressionRule].self, forKey: .memorySuppressionRules) ?? []
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

    public func deletionImpact(for captureIDs: Set<UUID>) -> MemoryDeletionImpact {
        MemoryGovernance.impact(of: captureIDs, in: state)
    }

    /// 将记录立即移出所有在线读取路径，并保留七天可恢复快照。
    @discardableResult
    public func moveCapturesToRecentlyDeleted(
        ids: Set<UUID>,
        reason: MemoryDeletionReason,
        suppressSimilar: Bool,
        now: Date = .now
    ) throws -> RecentlyDeletedMemory? {
        let previousState = state
        let removedCaptures = state.captures.filter { ids.contains($0.id) }
        guard !removedCaptures.isEmpty else { return nil }
        let actualIDs = Set(removedCaptures.map(\.id))
        let removedSummaries = state.dailySummaries.filter { !$0.sourceCaptureIDs.filter(actualIDs.contains).isEmpty }
        let removedMessages = state.messages.filter { $0.role == .assistant && !$0.citations.filter(actualIDs.contains).isEmpty }
        let removedReminders = state.reminders.filter { $0.origin != .manual && !$0.sourceCaptureIDs.filter(actualIDs.contains).isEmpty }
        let removedEpisodes = state.episodes.filter { !$0.evidenceIDs.filter(actualIDs.contains).isEmpty }
        let affectedProjects = state.projects.filter { !$0.evidenceIDs.filter(actualIDs.contains).isEmpty }
        let removedMemories = state.userMemories.filter { !$0.evidenceIDs.filter(actualIDs.contains).isEmpty }
        let removedInsights = state.insights.filter { !$0.evidenceIDs.filter(actualIDs.contains).isEmpty }
        let removedInsightIDs = Set(removedInsights.map(\.id))
        let removedFeedback = state.insightFeedback.filter { removedInsightIDs.contains($0.insightID) }
        let removedRoutines = state.learnedRoutines.filter { !$0.evidenceIDs.filter(actualIDs.contains).isEmpty }
        let checkpointHashes = Dictionary(uniqueKeysWithValues: actualIDs.compactMap { id in
            state.reminderDiscoveryCheckpoint.processedCaptureHashes[id.uuidString].map { (id.uuidString, $0) }
        })
        var addedRules: [MemorySuppressionRule] = []
        if suppressSimilar {
            let candidates = removedCaptures.compactMap { capture in
                MemorySuppressionRule.phrase(for: capture).map {
                    MemorySuppressionRule(phrase: $0, sourceBundleIdentifier: capture.sourceBundleIdentifier, reason: reason)
                }
            }
            var seen = Set(state.memorySuppressionRules.map { "\($0.sourceBundleIdentifier ?? "*")|\($0.normalizedPhrase)" })
            addedRules = candidates.filter { rule in
                seen.insert("\(rule.sourceBundleIdentifier ?? "*")|\(rule.normalizedPhrase)").inserted
            }
            state.memorySuppressionRules.append(contentsOf: addedRules)
        }
        let calendar = Calendar.current
        let days = Set(removedCaptures.map { calendar.startOfDay(for: $0.createdAt) })
            .union(Set(removedSummaries.map { calendar.startOfDay(for: $0.day) }))
            .sorted()
        let transaction = RecentlyDeletedMemory(
            label: removedCaptures.count == 1 ? (removedCaptures[0].summary ?? "1 条记忆") : "\(removedCaptures.count) 条记忆",
            reason: reason,
            expiresAt: calendar.date(byAdding: .day, value: MemoryGovernance.retentionDays, to: now) ?? now,
            captures: removedCaptures,
            summaries: removedSummaries,
            messages: removedMessages,
            reminders: removedReminders,
            episodes: removedEpisodes,
            projects: affectedProjects,
            userMemories: removedMemories,
            insights: removedInsights,
            insightFeedback: removedFeedback,
            routines: removedRoutines,
            checkpointHashes: checkpointHashes,
            affectedDays: days,
            previousConversationSummary: state.conversationSummary,
            previousConversationSummaryCoveredMessageCount: state.conversationSummaryCoveredMessageCount,
            addedSuppressionRuleIDs: addedRules.map(\.id)
        )
        state.captures.removeAll { actualIDs.contains($0.id) }
        state.dailySummaries.removeAll { summary in removedSummaries.contains(where: { $0.id == summary.id }) }
        state.messages.removeAll { message in removedMessages.contains(where: { $0.id == message.id }) }
        state.reminders.removeAll { reminder in removedReminders.contains(where: { $0.id == reminder.id }) }
        state.episodes.removeAll { episode in removedEpisodes.contains(where: { $0.id == episode.id }) }
        state.projects = state.projects.compactMap { project in
            guard actualIDs.contains(where: project.evidenceIDs.contains) else { return project }
            var updated = project
            updated.evidenceIDs.removeAll(where: actualIDs.contains)
            return updated.evidenceIDs.isEmpty ? nil : updated
        }
        state.userMemories.removeAll { memory in removedMemories.contains(where: { $0.id == memory.id }) }
        state.insights.removeAll { insight in removedInsights.contains(where: { $0.id == insight.id }) }
        state.insightFeedback.removeAll { removedInsightIDs.contains($0.insightID) }
        state.learnedRoutines.removeAll { routine in removedRoutines.contains(where: { $0.id == routine.id }) }
        for id in actualIDs { state.reminderDiscoveryCheckpoint.processedCaptureHashes.removeValue(forKey: id.uuidString) }
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = 0
        state.recentlyDeletedMemories.insert(transaction, at: 0)
        do {
            for path in transaction.screenshotPaths { try storage.moveScreenshotToRecentlyDeleted(relativePath: path) }
            try persist()
        } catch {
            state = previousState
            for path in transaction.screenshotPaths { try? storage.restoreScreenshot(relativePath: path) }
            throw error
        }
        return transaction
    }

    @discardableResult
    public func moveDailySummaryToRecentlyDeleted(
        id: UUID,
        reason: MemoryDeletionReason = .noLongerNeeded,
        now: Date = .now
    ) throws -> RecentlyDeletedMemory? {
        guard let summary = state.dailySummaries.first(where: { $0.id == id }) else { return nil }
        let transaction = RecentlyDeletedMemory(
            label: summary.day.formatted(date: .abbreviated, time: .omitted) + " 的每日总结",
            reason: reason,
            expiresAt: Calendar.current.date(byAdding: .day, value: MemoryGovernance.retentionDays, to: now) ?? now,
            summaries: [summary],
            affectedDays: [summary.day]
        )
        state.dailySummaries.removeAll { $0.id == id }
        state.recentlyDeletedMemories.insert(transaction, at: 0)
        try persist()
        return transaction
    }

    @discardableResult
    public func removeDailySummaryItem(
        summaryID: UUID,
        itemID: UUID,
        reason: MemoryDeletionReason,
        now: Date = .now
    ) throws -> RecentlyDeletedMemory? {
        guard let index = state.dailySummaries.firstIndex(where: { $0.id == summaryID }),
              let item = state.dailySummaries[index].items.first(where: { $0.id == itemID }) else { return nil }
        let original = state.dailySummaries[index]
        let transaction = RecentlyDeletedMemory(
            label: item.title,
            reason: reason,
            expiresAt: Calendar.current.date(byAdding: .day, value: MemoryGovernance.retentionDays, to: now) ?? now,
            summaries: [original],
            affectedDays: [original.day]
        )
        state.dailySummaries[index].items.removeAll { $0.id == itemID }
        state.dailySummaries[index].content = DailySummaryItemParser.markdown(from: state.dailySummaries[index].items)
        if item.section.canonical == .actions {
            let itemEvidence = Set(item.evidenceIDs)
            state.dailySummaries[index].todos.removeAll { todo in
                todo.title == item.title || (!itemEvidence.isEmpty && !todo.sourceCaptureIDs.filter(itemEvidence.contains).isEmpty)
            }
        }
        state.recentlyDeletedMemories.insert(transaction, at: 0)
        try persist()
        return transaction
    }

    @discardableResult
    public func restoreRecentlyDeleted(id: UUID) throws -> RecentlyDeletedMemory? {
        let previousState = state
        guard let index = state.recentlyDeletedMemories.firstIndex(where: { $0.id == id }) else { return nil }
        let transaction = state.recentlyDeletedMemories.remove(at: index)
        let captureIDs = Set(transaction.captures.map(\.id))
        state.captures.removeAll { captureIDs.contains($0.id) }
        state.captures.append(contentsOf: transaction.captures)
        state.captures.sort { $0.createdAt > $1.createdAt }
        for summary in transaction.summaries {
            state.dailySummaries.removeAll { $0.id == summary.id || Calendar.current.isDate($0.day, inSameDayAs: summary.day) }
            state.dailySummaries.append(summary)
        }
        state.dailySummaries.sort { $0.day > $1.day }
        Self.restoreUnique(transaction.messages, to: &state.messages, id: \.id)
        state.messages.sort { $0.createdAt < $1.createdAt }
        Self.restoreUnique(transaction.reminders, to: &state.reminders, id: \.id)
        let calendar = Calendar.current
        state.episodes.removeAll { episode in transaction.affectedDays.contains(where: { calendar.isDate(episode.day, inSameDayAs: $0) }) }
        Self.restoreUnique(transaction.episodes, to: &state.episodes, id: \.id)
        for project in transaction.projects {
            state.projects.removeAll { $0.projectKey == project.projectKey }
            state.projects.append(project)
        }
        let memoryKeys = Set(transaction.userMemories.map(\.key))
        state.userMemories.removeAll { memoryKeys.contains($0.key) }
        Self.restoreUnique(transaction.userMemories, to: &state.userMemories, id: \.id)
        state.insights.removeAll { insight in transaction.affectedDays.contains(where: { calendar.isDate(insight.day, inSameDayAs: $0) }) }
        Self.restoreUnique(transaction.insights, to: &state.insights, id: \.id)
        Self.restoreUnique(transaction.insightFeedback, to: &state.insightFeedback, id: \.id)
        let routineKeys = Set(transaction.routines.map(\.key))
        state.learnedRoutines.removeAll { routineKeys.contains($0.key) }
        Self.restoreUnique(transaction.routines, to: &state.learnedRoutines, id: \.id)
        state.reminderDiscoveryCheckpoint.processedCaptureHashes.merge(transaction.checkpointHashes) { _, restored in restored }
        if !transaction.captures.isEmpty {
            state.conversationSummary = transaction.previousConversationSummary
            state.conversationSummaryCoveredMessageCount = transaction.previousConversationSummaryCoveredMessageCount
        }
        let addedRuleIDs = Set(transaction.addedSuppressionRuleIDs)
        state.memorySuppressionRules.removeAll { addedRuleIDs.contains($0.id) }
        do {
            for path in transaction.screenshotPaths { try storage.restoreScreenshot(relativePath: path) }
            try persist()
        } catch {
            state = previousState
            for path in transaction.screenshotPaths { try? storage.moveScreenshotToRecentlyDeleted(relativePath: path) }
            throw error
        }
        return transaction
    }

    public func purgeRecentlyDeleted(id: UUID) throws {
        guard let item = state.recentlyDeletedMemories.first(where: { $0.id == id }) else { return }
        for path in item.screenshotPaths { try storage.permanentlyDeleteRecentlyDeletedScreenshot(relativePath: path) }
        state.recentlyDeletedMemories.removeAll { $0.id == id }
        try persist()
    }

    @discardableResult
    public func purgeExpiredRecentlyDeleted(now: Date = .now) throws -> Int {
        let expired = state.recentlyDeletedMemories.filter { $0.expiresAt <= now }
        for item in expired {
            for path in item.screenshotPaths { try storage.permanentlyDeleteRecentlyDeletedScreenshot(relativePath: path) }
        }
        let ids = Set(expired.map(\.id))
        state.recentlyDeletedMemories.removeAll { ids.contains($0.id) }
        if !expired.isEmpty { try persist() }
        return expired.count
    }

    public func removeSuppressionRule(id: UUID) throws {
        state.memorySuppressionRules.removeAll { $0.id == id }
        try persist()
    }

    private static func restoreUnique<Element, ID: Hashable>(_ values: [Element], to target: inout [Element], id: KeyPath<Element, ID>) {
        let ids = Set(values.map { $0[keyPath: id] })
        target.removeAll { ids.contains($0[keyPath: id]) }
        target.append(contentsOf: values)
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

    /// 永久清除全部记忆内容，但保留用户的事件、隐私、模型与定时设置。
    public func clearAllMemoryData() throws {
        let activePaths = state.captures.compactMap(\.imageRelativePath)
        let deletedPaths = state.recentlyDeletedMemories.flatMap(\.screenshotPaths)
        state.captures = []
        state.messages = []
        state.reminders = []
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
        state.reminderLearningProfile = ReminderLearningProfile()
        state.dailySummaries = []
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = 0
        state.episodes = []
        state.projects = []
        state.userMemories = []
        state.insights = []
        state.insightFeedback = []
        state.learnedRoutines = []
        state.recentlyDeletedMemories = []
        state.memorySuppressionRules = []
        try persist()
        for path in activePaths { try? storage.deleteScreenshot(relativePath: path) }
        for path in deletedPaths { try? storage.permanentlyDeleteRecentlyDeletedScreenshot(relativePath: path) }
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
        guard let removed = removeCaptureState(id: id) else { return nil }
        try persist()
        return removed
    }

    private func removeCaptureState(id: UUID) -> CaptureRecord? {
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
        state.messages.removeAll { $0.role == .assistant && $0.citations.contains(id) }
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = 0
        state.reminderDiscoveryCheckpoint.processedCaptureHashes.removeValue(forKey: id.uuidString)
        state.projects = state.projects.compactMap { project in
            var updated = project
            updated.evidenceIDs.removeAll { $0 == id }
            return updated.evidenceIDs.isEmpty ? nil : updated
        }
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
        let retainedIDs = Set(retained.map(\.id))
        let expiredIDs = state.captures.map(\.id).filter { !retainedIDs.contains($0) }
        for id in expiredIDs { _ = removeCaptureState(id: id) }
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
