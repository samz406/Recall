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
    public var weeklyReports: [WeeklyReport]
    public var reviewTemplates: [ReviewTemplate]
    public var reviewSchedules: [ReviewSchedule]
    public var reviewCategories: [String: ReviewCategory]
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
    public var matterCorrections: [MatterCorrection]
    public var dismissedExperienceIDs: [String]
    public var experienceHintsEnabled: Bool
    public var memoryKnowledge: MemoryKnowledge
    public var memoryKnowledgeSettings: MemoryKnowledgeSettings

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
        memorySuppressionRules: [MemorySuppressionRule] = [],
        matterCorrections: [MatterCorrection] = [],
        dismissedExperienceIDs: [String] = [],
        experienceHintsEnabled: Bool = false,
        weeklyReports: [WeeklyReport] = [],
        reviewTemplates: [ReviewTemplate] = [],
        reviewSchedules: [ReviewSchedule] = [],
        reviewCategories: [String: ReviewCategory] = [:],
        memoryKnowledge: MemoryKnowledge = MemoryKnowledge(),
        memoryKnowledgeSettings: MemoryKnowledgeSettings = MemoryKnowledgeSettings()
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
        self.matterCorrections = matterCorrections
        self.dismissedExperienceIDs = dismissedExperienceIDs
        self.experienceHintsEnabled = experienceHintsEnabled
        self.weeklyReports = weeklyReports
        self.reviewTemplates = reviewTemplates
        self.reviewSchedules = reviewSchedules
        self.reviewCategories = reviewCategories
        self.memoryKnowledge = memoryKnowledge
        self.memoryKnowledgeSettings = memoryKnowledgeSettings
    }

    private enum CodingKeys: String, CodingKey {
        case rules, captures, messages, reminders, reminderDiscoveryCheckpoint, reminderLearningProfile, dailySummaries, dailySummarySettings
        case privacy, llmConfiguration, conversationSummary, conversationSummaryCoveredMessageCount
        case weeklyReports, reviewTemplates, reviewSchedules, reviewCategories, memoryKnowledge, memoryKnowledgeSettings
        case episodes, projects, userMemories, insights, insightFeedback, learnedRoutines
        case recentlyDeletedMemories, memorySuppressionRules, matterCorrections, dismissedExperienceIDs, experienceHintsEnabled
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
        matterCorrections = try container.decodeIfPresent([MatterCorrection].self, forKey: .matterCorrections) ?? []
        dismissedExperienceIDs = try container.decodeIfPresent([String].self, forKey: .dismissedExperienceIDs) ?? []
        experienceHintsEnabled = try container.decodeIfPresent(Bool.self, forKey: .experienceHintsEnabled) ?? false
        weeklyReports = try container.decodeIfPresent([WeeklyReport].self, forKey: .weeklyReports) ?? []
        reviewTemplates = try container.decodeIfPresent([ReviewTemplate].self, forKey: .reviewTemplates) ?? []
        reviewSchedules = try container.decodeIfPresent([ReviewSchedule].self, forKey: .reviewSchedules) ?? []
        reviewCategories = try container.decodeIfPresent([String: ReviewCategory].self, forKey: .reviewCategories) ?? [:]
        memoryKnowledge = try container.decodeIfPresent(MemoryKnowledge.self, forKey: .memoryKnowledge) ?? MemoryKnowledge()
        memoryKnowledgeSettings = try container.decodeIfPresent(MemoryKnowledgeSettings.self, forKey: .memoryKnowledgeSettings) ?? MemoryKnowledgeSettings()
    }
}

public actor FileMemoryStore {
    let storage: RecallStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    var state: RecallState
    // Runtime identity prevents an in-flight answer from repopulating a cleared session.
    private var conversationID = UUID()
    private let intelligenceIndex: SQLiteIntelligenceIndex?
    private var indexNeedsRebuild = false

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
        state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state)
        try Self.write(state, encoder: encoder, to: storage.stateURL)
        do { try intelligenceIndex?.replace(with: state) } catch { indexNeedsRebuild = true }
    }

    public func snapshot() -> RecallState { state }

    public func conversationSnapshot() -> (id: UUID, state: RecallState) {
        (conversationID, state)
    }

    @discardableResult
    public func clearConversation() throws -> ConversationMessage {
        try Task.checkCancellation()
        let previous = state
        let previousID = conversationID
        let result = ConversationMessage(role: .system, content: "已清空当前会话，可以开始新的对话。")
        state.messages = [result]
        for i in state.memoryKnowledge.claims.indices where state.memoryKnowledge.claims[i].scope == .conversation {
            state.memoryKnowledge.claims[i].state = .expired
            state.memoryKnowledge.claims[i].validUntil = .now
        }
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = 0
        conversationID = UUID()
        // Messages and their compression aren't indexed in SQLite. One atomic state write
        // is sufficient, and avoids reporting failure after an unrelated index update.
        do { try Self.write(state, encoder: encoder, to: storage.stateURL) }
        catch {
            state = previous
            conversationID = previousID
            throw error
        }
        return result
    }

    public func saveMatterCorrection(_ correction: MatterCorrection) throws {
        let available = Set(state.captures.map(\.id))
        var correction = correction
        correction.evidenceIDs = correction.evidenceIDs.filter(available.contains)
        guard !correction.evidenceIDs.isEmpty else { return }
        state.matterCorrections.append(correction)
        invalidateMemoryOutputs(sourceIDs: Set(correction.evidenceIDs))
        // Prevent old assistant conclusions from surviving a correction via conversation compression.
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = state.messages.count
        if correction.kind == .completed || correction.kind == .notMine || correction.kind == .inaccurate {
            for i in state.reminders.indices {
                guard !Set(state.reminders[i].sourceCaptureIDs).isDisjoint(with: correction.evidenceIDs) else { continue }
                if correction.kind == .completed {
                    state.reminders[i].status = .completed
                    state.reminders[i].completedAt = correction.createdAt
                } else if state.reminders[i].origin == .discovered && state.reminders[i].status == .proposed {
                    state.reminders[i].status = .dismissed
                }
                state.reminders[i].updatedAt = correction.createdAt
            }
        }
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
        try persist()
    }

    public func removeMatterCorrection(id: UUID) throws {
        let sourceIDs = Set(state.matterCorrections.filter { $0.id == id }.flatMap(\.evidenceIDs))
        invalidateMemoryOutputs(sourceIDs: sourceIDs)
        state.matterCorrections.removeAll { $0.id == id }
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = 0
        try persist()
    }

    public func setExperienceHints(enabled: Bool) throws {
        state.experienceHintsEnabled = enabled
        try persist()
    }

    public func dismissExperience(id: String) throws {
        if !state.dismissedExperienceIDs.contains(id) { state.dismissedExperienceIDs.append(id) }
        try persist()
    }

    public func isIntelligenceIndexAvailable() -> Bool { intelligenceIndex != nil }
    public func memoryIndexNeedsRebuild() -> Bool { indexNeedsRebuild || intelligenceIndex == nil }

    public func indexedCaptureIDs(matching query: String, limit: Int = 12) -> [UUID] {
        guard !indexNeedsRebuild else { return [] }
        return (try? intelligenceIndex?.searchCaptureIDs(matching: query, limit: limit)) ?? []
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

    private func invalidateWeeklyReports() {
        for i in state.weeklyReports.indices where state.weeklyReports[i].isReadable {
            if !WeeklyReviewEngine.sourcesUnchanged(state.weeklyReports[i], in: state) { state.weeklyReports[i].invalidate() }
        }
        for i in state.recentlyDeletedMemories.indices {
            guard var reports = state.recentlyDeletedMemories[i].weeklyReports else { continue }
            // A source in this same deletion transaction can be restored together with its report.
            var restorationState = state
            let existing = Set(state.captures.map(\.id))
            restorationState.captures += state.recentlyDeletedMemories[i].captures.filter { !existing.contains($0.id) }
            restorationState.matterCorrections += state.recentlyDeletedMemories[i].matterCorrections ?? []
            for j in reports.indices where reports[j].isReadable {
                if !WeeklyReviewEngine.sourcesUnchanged(reports[j], in: restorationState) { reports[j].invalidate() }
            }
            state.recentlyDeletedMemories[i].weeklyReports = reports
        }
    }

    public func saveReviewTemplate(_ template: ReviewTemplate) throws {
        guard template.isValid else { throw WeeklyReviewError.invalidTemplate }
        let before = state
        state.reviewTemplates.removeAll { $0.id == template.id }
        state.reviewTemplates.append(template)
        do { try persist() } catch { state = before; throw error }
    }

    public func deleteReviewTemplate(id: String) throws {
        let before = state
        state.reviewTemplates.removeAll { $0.id == id }
        do { try persist() } catch { state = before; throw error }
    }

    public func saveReviewCategory(topicID: String, category: ReviewCategory) throws {
        let before = state
        state.reviewCategories[topicID] = category
        // A work/life boundary changed. Old exported drafts must be reviewed again.
        for i in state.weeklyReports.indices where state.weeklyReports[i].items.contains(where: { $0.id == topicID }) {
            state.weeklyReports[i].invalidate()
        }
        for i in state.recentlyDeletedMemories.indices {
            guard var reports = state.recentlyDeletedMemories[i].weeklyReports else { continue }
            for j in reports.indices where reports[j].items.contains(where: { $0.id == topicID }) { reports[j].invalidate() }
            state.recentlyDeletedMemories[i].weeklyReports = reports
        }
        do { try persist() } catch { state = before; throw error }
    }

    public func saveReviewSchedule(_ schedule: ReviewSchedule, now: Date = .now) throws {
        guard schedule.isValid else { throw WeeklyReviewError.invalidTemplate }
        let before = state
        var value = schedule
        let old = state.reviewSchedules.first { $0.id == value.id }
        if old != value || value.nextRunAt == nil {
            value.nextRunAt = value.nextTrigger(after: now); value.retryAfter = nil
            value.failureCount = 0; value.lastReportID = nil
        }
        state.reviewSchedules.removeAll { $0.id == value.id }; state.reviewSchedules.append(value)
        do { try persist() } catch { state = before; throw error }
    }

    public func deleteReviewSchedule(id: UUID) throws {
        let before = state
        state.reviewSchedules.removeAll { $0.id == id }
        do { try persist() } catch { state = before; throw error }
    }

    public func commitWeeklyReport(_ submitted: WeeklyReport, replacing id: UUID? = nil,
                                   schedule expected: ReviewSchedule? = nil, categories: [String: ReviewCategory]? = nil,
                                   now: Date = .now) throws -> WeeklyReport {
        try Task.checkCancellation()
        guard WeeklyReviewEngine.sourcesUnchanged(submitted, in: state),
              categories == nil || categories == state.reviewCategories else { throw WeeklyReviewError.changedSources }
        if let expected {
            guard state.reviewSchedules.contains(expected), expected.isDue(at: now),
                  let trigger = submitted.scheduledFor ?? expected.effectiveTrigger(at: now),
                  submitted.period == expected.period(at: trigger),
                  submitted.template == expected.template, submitted.scope == expected.scope else { throw WeeklyReviewError.changedSources }
        }
        let before = state
        var report = submitted
        if let id, !state.weeklyReports.contains(where: { $0.id == id }) { throw WeeklyReviewError.changedSources }
        if let id, let old = state.weeklyReports.first(where: { $0.id == id }) {
            // Never silently overwrite an edited draft during a scheduled retry.
            guard expected == nil || old.editedMarkdown == nil else { throw WeeklyReviewError.changedSources }
            report.id = id; report.createdAt = old.createdAt
        }
        if let expected {
            report.scheduleID = expected.id; report.scheduledFor = submitted.scheduledFor ?? expected.nextRunAt
            guard let i = state.reviewSchedules.firstIndex(where: { $0.id == expected.id }) else { throw WeeklyReviewError.changedSources }
            state.reviewSchedules[i].lastReportID = report.id
            // A readable local report completes this period even if the optional model failed.
            state.reviewSchedules[i].nextRunAt = expected.nextTrigger(after: now)
            state.reviewSchedules[i].retryAfter = nil; state.reviewSchedules[i].failureCount = 0
            if report.refinementPending { report.recordRefinementAttempt(at: now) }
        }

        state.weeklyReports.removeAll { $0.id == report.id }; state.weeklyReports.insert(report, at: 0)
        do { try persist() } catch { state = before; throw error }
        return report
    }

    public func commitWeeklyRefinement(_ submitted: WeeklyReport, expected original: WeeklyReport,
                                       schedule: ReviewSchedule, categories: [String: ReviewCategory]? = nil,
                                       now: Date = .now) throws -> WeeklyReport {
        try Task.checkCancellation()
        guard state.weeklyReports.contains(original), original.canRefine(at: now),
              state.reviewSchedules.contains(schedule), schedule.isEnabled, schedule.useModel,
              schedule.id == original.scheduleID, schedule.lastReportID == original.id,
              schedule.template == original.template, schedule.scope == original.scope,
              submitted.id == original.id, submitted.period == original.period,
              submitted.template == original.template, submitted.scope == original.scope,
              submitted.sourceVersions == original.sourceVersions,
              WeeklyReviewEngine.sourcesUnchanged(submitted, in: state),
              categories == nil || categories == state.reviewCategories else { throw WeeklyReviewError.changedSources }
        let before = state
        var report = submitted
        report.recordRefinementAttempt(at: now)
        state.weeklyReports.removeAll { $0.id == original.id }; state.weeklyReports.insert(report, at: 0)
        do { try persist() } catch { state = before; throw error }
        return report
    }

    public func deferWeeklyRefinement(_ original: WeeklyReport, schedule: ReviewSchedule, now: Date = .now) throws {
        var deferred = original; deferred.updatedAt = now; deferred.refinementPending = true
        _ = try commitWeeklyRefinement(deferred, expected: original, schedule: schedule, now: now)
    }

    public func deferReviewSchedule(_ expected: ReviewSchedule, noEvidence: Bool, now: Date = .now) throws {
        guard let i = state.reviewSchedules.firstIndex(where: { $0 == expected }) else { return }
        let before = state
        if noEvidence {
            state.reviewSchedules[i].nextRunAt = expected.nextTrigger(after: now)
            state.reviewSchedules[i].retryAfter = nil; state.reviewSchedules[i].failureCount = 0
        } else {
            state.reviewSchedules[i].failureCount += 1
            state.reviewSchedules[i].retryAfter = now.addingTimeInterval(min(3600, 60 * pow(2, Double(min(state.reviewSchedules[i].failureCount, 6)))))
        }
        do { try persist() } catch { state = before; throw error }
    }

    public func editWeeklyReport(id: UUID, markdown: String?) throws {
        guard let i = state.weeklyReports.firstIndex(where: { $0.id == id && $0.isReadable }) else { throw WeeklyReviewError.changedSources }
        let before = state
        if let markdown {
            let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty && text.count <= 60_000 else { throw WeeklyReviewError.invalidTemplate }
            state.weeklyReports[i].editedMarkdown = text
            state.weeklyReports[i].refinementPending = false
        } else { state.weeklyReports[i].editedMarkdown = nil }
        state.weeklyReports[i].updatedAt = .now
        do { try persist() } catch { state = before; throw error }
    }

    @discardableResult
    public func deleteWeeklyReport(id: UUID, now: Date = .now) throws -> RecentlyDeletedMemory? {
        guard let report = state.weeklyReports.first(where: { $0.id == id }) else { return nil }
        let before = state
        var deleted = RecentlyDeletedMemory(label: report.template.name + " · " + report.period.label, reason: .noLongerNeeded,
            deletedAt: now, expiresAt: Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now)
        deleted.weeklyReports = [report]
        for i in state.reviewSchedules.indices where state.reviewSchedules[i].lastReportID == id {
            state.reviewSchedules[i].nextRunAt = state.reviewSchedules[i].nextTrigger(after: now)
            state.reviewSchedules[i].lastReportID = nil
            state.reviewSchedules[i].retryAfter = nil; state.reviewSchedules[i].failureCount = 0
        }
        state.weeklyReports.removeAll { $0.id == id }; state.recentlyDeletedMemories.insert(deleted, at: 0)
        do { try persist() } catch { state = before; throw error }
        return deleted
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
        var transaction = RecentlyDeletedMemory(
            label: removedCaptures.count == 1 ? (removedCaptures[0].summary ?? "1 条记忆") : "\(removedCaptures.count) 条记忆",
            reason: reason,
            deletedAt: now,
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
        transaction.weeklyReports = state.weeklyReports.filter { !$0.sourceIDs.isDisjoint(with: actualIDs) }
        transaction.matterCorrections = state.matterCorrections.filter { !Set($0.evidenceIDs).isDisjoint(with: actualIDs) }
        state.matterCorrections.removeAll { !Set($0.evidenceIDs).isDisjoint(with: actualIDs) }
        state.captures.removeAll { actualIDs.contains($0.id) }
        state.dailySummaries.removeAll { summary in removedSummaries.contains(where: { $0.id == summary.id }) }
        state.messages.removeAll { message in removedMessages.contains(where: { $0.id == message.id }) }
        state.reminders.removeAll { reminder in removedReminders.contains(where: { $0.id == reminder.id }) }
        state.episodes.removeAll { episode in removedEpisodes.contains(where: { $0.id == episode.id }) }
        state.projects = state.projects.compactMap { project in
            guard actualIDs.contains(where: project.evidenceIDs.contains) else { return project }
            return nil
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
            deletedAt: now,
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
            deletedAt: now,
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
    public func restoreRecentlyDeleted(id: UUID, now: Date = .now) throws -> RecentlyDeletedMemory? {
        let previousState = state
        guard let index = state.recentlyDeletedMemories.firstIndex(where: { $0.id == id }) else { return nil }
        guard state.recentlyDeletedMemories[index].expiresAt > now else {
            throw RecentlyDeletedRestoreError.expired
        }
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
        Self.restoreUnique(transaction.weeklyReports ?? [], to: &state.weeklyReports, id: \.id)
        Self.restoreUnique(transaction.messages, to: &state.messages, id: \.id)
        state.messages.sort { $0.createdAt < $1.createdAt }
        Self.restoreUnique(transaction.reminders, to: &state.reminders, id: \.id)
        let calendar = Calendar.current
        state.episodes.removeAll { episode in transaction.affectedDays.contains(where: { calendar.isDate(episode.day, inSameDayAs: $0) }) }
        Self.restoreUnique(transaction.episodes, to: &state.episodes, id: \.id)
        Self.restoreUnique(transaction.matterCorrections ?? [], to: &state.matterCorrections, id: \.id)
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
        let previousState = state
        state.recentlyDeletedMemories.removeAll { $0.id == id }
        do { try persist() } catch { state = previousState; throw error }
    }

    @discardableResult
    public func purgeExpiredRecentlyDeleted(now: Date = .now) throws -> Int {
        let expired = state.recentlyDeletedMemories.filter { $0.expiresAt <= now }
        guard !expired.isEmpty else { return 0 }
        for item in expired {
            for path in item.screenshotPaths { try storage.permanentlyDeleteRecentlyDeletedScreenshot(relativePath: path) }
        }
        let previousState = state
        let ids = Set(expired.map(\.id))
        state.recentlyDeletedMemories.removeAll { ids.contains($0.id) }
        do { try persist() } catch { state = previousState; throw error }
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
        state.memoryKnowledge = MemoryKnowledge()
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
        state.weeklyReports = []
        state.reviewCategories = [:]
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = 0
        state.memoryKnowledge = MemoryKnowledge()
        state.episodes = []
        state.projects = []
        state.userMemories = []
        state.insights = []
        state.insightFeedback = []
        state.learnedRoutines = []
        state.recentlyDeletedMemories = []
        state.memorySuppressionRules = []
        state.matterCorrections = []
        state.dismissedExperienceIDs = []
        try persist()
        conversationID = UUID()
        for path in activePaths { try? storage.deleteScreenshot(relativePath: path) }
        for path in deletedPaths { try? storage.permanentlyDeleteRecentlyDeletedScreenshot(relativePath: path) }
    }

    public func updateConversationSummary(_ summary: String?, coveredMessageCount: Int, inConversation expectedID: UUID? = nil) throws {
        if expectedID != nil { try Task.checkCancellation() }
        if let expectedID, expectedID != conversationID { throw CancellationError() }
        state.conversationSummary = summary
        state.conversationSummaryCoveredMessageCount = coveredMessageCount
        try persist()
    }

    public func addCapture(_ capture: CaptureRecord) throws {
        state.captures.insert(capture, at: 0)
        try persist()
    }

    @discardableResult
    public func addManualMatter(_ note: ManualMatterNote, now: Date = .now) throws -> CaptureRecord {
        let record = try note.capture(recordedAt: now)
        let previous = state
        do {
            state.captures.insert(record, at: 0)
            try persist()
        } catch {
            state = previous
            throw error
        }
        return record
    }

    public func deleteCapture(id: UUID) throws -> CaptureRecord? {
        guard let removed = removeCaptureState(id: id) else { return nil }
        try persist()
        return removed
    }

    private func removeCaptureState(id: UUID) -> CaptureRecord? {
        guard let index = state.captures.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = state.captures.remove(at: index)
        state.matterCorrections.removeAll { $0.evidenceIDs.contains(id) }
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
            return project.evidenceIDs.contains(id) ? nil : project
        }
        return removed
    }

    public func addMessage(_ message: ConversationMessage, inConversation expectedID: UUID? = nil) throws {
        if expectedID != nil { try Task.checkCancellation() }
        if let expectedID, expectedID != conversationID { throw CancellationError() }
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
        let previous = state
        var paths = Set(state.memoryKnowledge.pendingScreenshotDeletions)
        var expired: [UUID] = []
        let durableIDs = Set(state.memoryKnowledge.claims.filter { $0.explicit && $0.usable(at: now) }.flatMap(\.sourceIDs))
        for i in state.captures.indices {
            let record = state.captures[i]
            guard let rule = state.rules.first(where: { $0.template == record.eventTemplate }) else { continue }
            let age = now.timeIntervalSince(record.createdAt)
            if let path = record.imageRelativePath, age > Double(rule.retainImageDays) * 86_400 {
                paths.insert(path)
                state.captures[i].imageRelativePath = nil
            }
            guard age > Double(rule.retainTextDays) * 86_400 else { continue }
            if let directive = record.memoryDirective, state.memoryKnowledgeSettings.retainExplicitMemories,
               directive.scope != .conversation, durableIDs.contains(record.id) {
                if let path = record.imageRelativePath { paths.insert(path) }
                // Keep only the user's explicit agreement and minimal attribution, not the original screen.
                state.captures[i].ocrText = directive.content
                state.captures[i].summary = nil
                state.captures[i].windowTitle = nil
                state.captures[i].tags = []
                state.captures[i].imageRelativePath = nil
                state.captures[i].isMemoryEvidenceArchive = true
            } else {
                if let path = record.imageRelativePath { paths.insert(path) }
                expired.append(record.id)
            }
        }
        for id in expired { _ = removeCaptureState(id: id) }
        state.memoryKnowledge.pendingScreenshotDeletions = Array(paths).sorted()
        do { try persist() } catch { state = previous; throw error }
        return Array(paths).sorted()
    }

    func persist() throws {
        invalidateWeeklyReports()
        state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state)
        try Self.write(state, encoder: encoder, to: storage.stateURL)
        do {
            if indexNeedsRebuild { try intelligenceIndex?.replace(with: state) }
            else { try intelligenceIndex?.synchronize(with: state) }
            indexNeedsRebuild = false
        } catch { indexNeedsRebuild = true }
    }

    private static func write(_ state: RecallState, encoder: JSONEncoder, to url: URL) throws {
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }
}
