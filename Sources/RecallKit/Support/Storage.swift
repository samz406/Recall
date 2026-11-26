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
    public let reviewSchedulesURL: URL
    public let conversationURL: URL

    public init(fileManager: FileManager = .default) throws {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecallStorageError.missingApplicationSupportDirectory
        }
        rootURL = appSupport.appendingPathComponent("Recall", isDirectory: true)
        screenshotsURL = rootURL.appendingPathComponent("Screenshots", isDirectory: true)
        recentlyDeletedScreenshotsURL = rootURL.appendingPathComponent("Recently Deleted/Screenshots", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("recall-state.json")
        intelligenceDatabaseURL = rootURL.appendingPathComponent("recall-intelligence.sqlite")
        reviewSchedulesURL = rootURL.appendingPathComponent("review-schedules.json")
        conversationURL = rootURL.appendingPathComponent("conversation.json")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        try fileManager.createDirectory(at: screenshotsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: recentlyDeletedScreenshotsURL, withIntermediateDirectories: true)
    }

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        screenshotsURL = rootURL.appendingPathComponent("Screenshots", isDirectory: true)
        recentlyDeletedScreenshotsURL = rootURL.appendingPathComponent("Recently Deleted/Screenshots", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("recall-state.json")
        intelligenceDatabaseURL = rootURL.appendingPathComponent("recall-intelligence.sqlite")
        reviewSchedulesURL = rootURL.appendingPathComponent("review-schedules.json")
        conversationURL = rootURL.appendingPathComponent("conversation.json")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        try fileManager.createDirectory(at: screenshotsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
    public var dataGeneration: UUID? = nil
    public var pendingFileDeletions: [String]? = nil
    public var pendingRecoveryCleanup: Bool? = nil
    public var schemaVersion = 2
    public var workflow = WorkflowSettings()
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
    public var topicReviews: [TopicModelReview] = []
    public var understandingJobs: [CaptureUnderstandingJob] = []
    public var understandingSettings = CaptureUnderstandingSettings()
    public var dailyReviewCheckpoints: [DailyReviewCheckpoint] = []
    public var pendingDailyReviewMaintenance: [UUID] = []
    public var dailyReviewAttemptedDays: [Date] = []
    public var summaryFeedback: [SummaryFeedback] = []
    public var summaryFeedbackSettings = SummaryFeedbackSettings()
    public var topicGroups: [MemoryTopicGroup] = []
    /// 旧主题键 → 规范主题键。用户合并主题后把旧名写进来，换个叫法的新记录仍归到同一主题。
    public var topicAliases: [String: String] = [:]
    /// 主题的稳定身份、别名与生命周期。首次在有每日回顾的存档上启动时自动迁移。
    public var topicRegistry: TopicRegistry = TopicRegistry()
    public var dismissedExperienceIDs: [String]
    public var experienceHintsEnabled: Bool
    public var memoryKnowledge: MemoryKnowledge
    public var memoryKnowledgeSettings: MemoryKnowledgeSettings
    public var pendingPersonaRefresh: [UUID] = []
    public var personaTraitObservations: [PersonaTraitObservation] = []
    public var personaTraits: [PersonaTraitState] = []
    public var dismissedPersonaDimensions: [PersonaDimension] = []
    public var personaProfileSettings = PersonaProfileSettings()
    public var personaRefreshJobs: [PersonaRefreshJob] = []
    public var personaProfileRevision = UUID()
    public var personaProfileVersion = 0
    public var rejectedPersonaEvidence: [String] = []
    /// Outcome and duration only, newest last, capped. No review text or error detail.
    public var reviewAttemptMetrics: [ReviewAttemptMetric] = []
    public var attentionSettings = AttentionSettings()
    /// Proactive notices that went past the daily budget wait here instead of interrupting.
    public var attentionInbox: [AttentionNotice] = []
    public var meetingBriefSettings = MeetingBriefSettings()

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
        case dataGeneration, pendingFileDeletions, pendingRecoveryCleanup
        case schemaVersion, workflow
        case topicReviews, understandingJobs, understandingSettings, dailyReviewCheckpoints, pendingDailyReviewMaintenance
        case dailyReviewAttemptedDays
        case summaryFeedback, summaryFeedbackSettings
        case rules, captures, messages, reminders, reminderDiscoveryCheckpoint, reminderLearningProfile, dailySummaries, dailySummarySettings
        case privacy, llmConfiguration, conversationSummary, conversationSummaryCoveredMessageCount
        case weeklyReports, reviewTemplates, reviewSchedules, reviewCategories, memoryKnowledge, memoryKnowledgeSettings
        case episodes, projects, userMemories, insights, insightFeedback, learnedRoutines
        case recentlyDeletedMemories, memorySuppressionRules, matterCorrections, dismissedExperienceIDs, experienceHintsEnabled, topicGroups, topicAliases, topicRegistry
        case pendingPersonaRefresh, personaTraitObservations, personaTraits
        case personaProfileSettings, personaRefreshJobs, personaProfileRevision, personaProfileVersion, rejectedPersonaEvidence
        case dismissedPersonaDimensions
        case reviewAttemptMetrics, attentionSettings, attentionInbox, meetingBriefSettings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataGeneration = try container.decodeIfPresent(UUID.self, forKey: .dataGeneration)
        pendingFileDeletions = try container.decodeIfPresent([String].self, forKey: .pendingFileDeletions)
        pendingRecoveryCleanup = try container.decodeIfPresent(Bool.self, forKey: .pendingRecoveryCleanup)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion <= 2 else { throw WorkflowError.changed }
        schemaVersion = 2
        workflow = try container.decodeIfPresent(WorkflowSettings.self, forKey: .workflow) ?? WorkflowSettings()
        topicReviews = try container.decodeIfPresent([TopicModelReview].self, forKey: .topicReviews) ?? []
        understandingJobs = try container.decodeIfPresent([CaptureUnderstandingJob].self, forKey: .understandingJobs) ?? []
        understandingSettings = try container.decodeIfPresent(CaptureUnderstandingSettings.self, forKey: .understandingSettings) ?? CaptureUnderstandingSettings()
        dailyReviewCheckpoints = try container.decodeIfPresent([DailyReviewCheckpoint].self, forKey: .dailyReviewCheckpoints) ?? []
        pendingDailyReviewMaintenance = try container.decodeIfPresent([UUID].self, forKey: .pendingDailyReviewMaintenance) ?? []
        dailyReviewAttemptedDays = try container.decodeIfPresent([Date].self, forKey: .dailyReviewAttemptedDays) ?? []
        summaryFeedback = try container.decodeIfPresent([SummaryFeedback].self, forKey: .summaryFeedback) ?? []
        summaryFeedbackSettings = try container.decodeIfPresent(SummaryFeedbackSettings.self, forKey: .summaryFeedbackSettings) ?? SummaryFeedbackSettings()
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
        topicGroups = try container.decodeIfPresent([MemoryTopicGroup].self, forKey: .topicGroups) ?? []
        topicAliases = try container.decodeIfPresent([String: String].self, forKey: .topicAliases) ?? [:]
        topicRegistry = try container.decodeIfPresent(TopicRegistry.self, forKey: .topicRegistry) ?? TopicRegistry()
        matterCorrections = try container.decodeIfPresent([MatterCorrection].self, forKey: .matterCorrections) ?? []
        dismissedExperienceIDs = try container.decodeIfPresent([String].self, forKey: .dismissedExperienceIDs) ?? []
        experienceHintsEnabled = try container.decodeIfPresent(Bool.self, forKey: .experienceHintsEnabled) ?? false
        weeklyReports = try container.decodeIfPresent([WeeklyReport].self, forKey: .weeklyReports) ?? []
        reviewTemplates = try container.decodeIfPresent([ReviewTemplate].self, forKey: .reviewTemplates) ?? []
        reviewSchedules = try container.decodeIfPresent([ReviewSchedule].self, forKey: .reviewSchedules) ?? []
        reviewCategories = try container.decodeIfPresent([String: ReviewCategory].self, forKey: .reviewCategories) ?? [:]
        memoryKnowledge = try container.decodeIfPresent(MemoryKnowledge.self, forKey: .memoryKnowledge) ?? MemoryKnowledge()
        memoryKnowledgeSettings = try container.decodeIfPresent(MemoryKnowledgeSettings.self, forKey: .memoryKnowledgeSettings) ?? MemoryKnowledgeSettings()
        pendingPersonaRefresh = try container.decodeIfPresent([UUID].self, forKey: .pendingPersonaRefresh) ?? []
        personaTraitObservations = try container.decodeIfPresent([PersonaTraitObservation].self, forKey: .personaTraitObservations) ?? []
        personaTraits = try container.decodeIfPresent([PersonaTraitState].self, forKey: .personaTraits) ?? []
        personaProfileSettings = try container.decodeIfPresent(PersonaProfileSettings.self, forKey: .personaProfileSettings) ?? PersonaProfileSettings()
        personaRefreshJobs = try container.decodeIfPresent([PersonaRefreshJob].self, forKey: .personaRefreshJobs) ?? []
        personaProfileRevision = try container.decodeIfPresent(UUID.self, forKey: .personaProfileRevision) ?? UUID()
        personaProfileVersion = try container.decodeIfPresent(Int.self, forKey: .personaProfileVersion) ?? 0
        rejectedPersonaEvidence = try container.decodeIfPresent([String].self, forKey: .rejectedPersonaEvidence) ?? []
        dismissedPersonaDimensions = try container.decodeIfPresent([PersonaDimension].self, forKey: .dismissedPersonaDimensions) ?? []
        reviewAttemptMetrics = try container.decodeIfPresent([ReviewAttemptMetric].self, forKey: .reviewAttemptMetrics) ?? []
        attentionSettings = try container.decodeIfPresent(AttentionSettings.self, forKey: .attentionSettings) ?? AttentionSettings()
        attentionInbox = try container.decodeIfPresent([AttentionNotice].self, forKey: .attentionInbox) ?? []
        meetingBriefSettings = try container.decodeIfPresent(MeetingBriefSettings.self, forKey: .meetingBriefSettings) ?? MeetingBriefSettings()
    }
}

private struct ReviewScheduleSidecar: Codable {
    var reviewSchedules: [ReviewSchedule]
}

public actor FileMemoryStore {
    let storage: RecallStorage
    let credentials: any CredentialStore
    var pendingLegacyCredential: (id: UUID, key: String)?
    public internal(set) var credentialMaintenanceWarning: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    var state: RecallState
    var activeDailyReviewDays: Set<Date> = []
    // Runtime identity prevents an in-flight answer from repopulating a cleared session.
    private var conversationID = UUID()
    private let intelligenceIndex: SQLiteIntelligenceIndex?
    private var indexNeedsRebuild = false
    /// Corrected copy reused by 问一问 until a memory write. Chat messages do not clear it.
    var personaRefreshInFlight = false
    private var chatAnalysis: RecallState?
    private var startupMaintenancePending = false
    private var committedState: RecallState?
    private var lastDiskDigest: String?
    var archiveRevision: UInt64 = 0
    /// Changes only when the set of captures or their searchable text changes. Chat writes,
    /// reminders and preferences do not bump it, so 问一问 can skip re-comparing every screenshot.
    /// 各作用域的会话消息与上一轮来源，随 conversation.json 一起落盘。
    private var conversationArchive = ConversationArchive()
    private var captureDigest: Int?
    private var captureContentRev: UInt64 = 0

    public func captureContentRevision() -> UInt64 { captureContentRev }

    private func refreshCaptureRevision() {
        var hasher = Hasher()
        for capture in state.captures {
            hasher.combine(capture.id)
            hasher.combine(capture.searchableText)
        }
        let digest = hasher.finalize()
        if digest != captureDigest { captureDigest = digest; captureContentRev &+= 1 }
    }
    var backgroundMaintenanceInFlight = false
    private var lastMaintenanceRevision: UInt64?
    public private(set) var backupPending = false

    public init() throws {
        try self.init(storage: RecallStorage())
    }

    /// Reading, verifying and decoding a large archive must not block the main thread.
    public static func open(storage: RecallStorage, deferMaintenance: Bool = false, credentials: any CredentialStore = KeychainCredentialStore.shared) async throws -> FileMemoryStore {
        try await Task.detached(priority: .userInitiated) {
            try FileMemoryStore(storage: storage, deferMaintenance: deferMaintenance, credentials: credentials)
        }.value
    }

    public init(storage: RecallStorage, deferMaintenance: Bool = false, credentials: any CredentialStore = KeychainCredentialStore.shared) throws {
        self.credentials = credentials
        self.storage = storage
        intelligenceIndex = try? SQLiteIntelligenceIndex(databaseURL: storage.intelligenceDatabaseURL)
        encoder = JSONEncoder()
        // Compact output keeps the archive smaller, so every load and save reads or writes fewer bytes.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var initialDigest: String?
        if FileManager.default.fileExists(atPath: storage.stateURL.path) {
            let data = try Data(contentsOf: storage.stateURL)
            initialDigest = ArchiveReliability.digest(data)
            var restoredState = try ArchiveReliability.decode(data)
            Self.overlayNewerReviewSchedules(&restoredState, storage: storage, decoder: decoder)
            // 会话消息以 sidecar 为准。旧存档里仍带消息时先写 sidecar，
            // 下一次写盘就不再把它们放进主存档。
            if let archive = ConversationStore.readArchive(from: storage.conversationURL, decoder: decoder) {
                conversationArchive = archive
                restoredState.messages = archive.scopes[archive.activeScope]?.messages ?? []
            } else if !restoredState.messages.isEmpty {
                conversationArchive.scopes[ConversationArchive.globalScope] = .init(messages: restoredState.messages)
                try? ConversationStore.write(restoredState.messages, to: storage.conversationURL, encoder: encoder)
            }
            if !restoredState.llmConfiguration.apiKey.isEmpty {
                var config = restoredState.llmConfiguration
                // A pre-ID archive must find the same Keychain item after an interrupted migration.
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let savedConfig = json?["llmConfiguration"] as? [String: Any]
                if savedConfig?["connectionID"] == nil {
                    config.connectionID = MatterEvidence.eventID(source: UUID(uuidString: "9BC4F467-7190-4A65-AC39-E591E87A1817")!, topic: storage.rootURL.standardizedFileURL.path, ordinal: 0)
                }
                do {
                    if try credentials.read(config.connectionID) == nil { try credentials.write(config.apiKey, id: config.connectionID) }
                    guard try credentials.read(config.connectionID) != nil else { throw CredentialError.unavailable }
                    config.apiKey = ""; config.credentialReference = config.connectionID.uuidString; config.credentialRevision += 1
                    restoredState.llmConfiguration = config
                    initialDigest = try Self.write(restoredState, encoder: encoder, to: storage.stateURL, expectedDigest: initialDigest)
                } catch {
                    pendingLegacyCredential = (config.connectionID, config.apiKey)
                    config.apiKey = ""; config.credentialReference = nil; restoredState.llmConfiguration = config
                    credentialMaintenanceWarning = "Credential migration pending. Local records are read-only until Keychain is available."
                }
            }
            if pendingLegacyCredential == nil && !deferMaintenance {
                do { try Self.scrubLegacyBackups(in: storage.rootURL) }
                catch { credentialMaintenanceWarning = "Legacy backup cleanup failed; retry from Settings." }
            }
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
            let credentialsReady = pendingLegacyCredential == nil
            if !deferMaintenance && credentialsReady {
                initialDigest = try Self.write(restoredState, encoder: encoder, to: storage.stateURL, expectedDigest: initialDigest)
            }
            // 主题登记表首次迁移：只迁移有每日回顾的存档，重复运行得到同一组 ID。
            if restoredState.topicRegistry.topics.isEmpty, !restoredState.dailySummaries.isEmpty {
                let registry = TopicRegistry.migrated(from: restoredState)
                if !registry.topics.isEmpty {
                    restoredState.topicRegistry = registry
                    // 一次性改写现有引用：合并组、完成标记、主题小结都改挂到稳定 ID，
                    // 界面里的查找不用再关心旧键。
                    for i in restoredState.topicReviews.indices {
                        restoredState.topicReviews[i].id = registry.rewritten(restoredState.topicReviews[i].id)
                    }
                    for i in restoredState.matterCorrections.indices {
                        if let topicID = restoredState.matterCorrections[i].topicID {
                            restoredState.matterCorrections[i].topicID = registry.rewritten(topicID)
                        }
                    }
                    for i in restoredState.topicGroups.indices {
                        restoredState.topicGroups[i].memberIDs = restoredState.topicGroups[i].memberIDs.map { registry.rewritten($0) }
                    }
                    do { initialDigest = try Self.write(restoredState, encoder: encoder, to: storage.stateURL, expectedDigest: initialDigest) }
                    catch { credentialMaintenanceWarning = "Topic registry migration pending. Saved topics remain readable." }
                }
            }
            state = restoredState
        } else {
            guard ArchiveReliability.backups(storage).isEmpty else { throw ArchiveReliabilityError.missingPrimary }
            state = RecallState()
            initialDigest = try Self.write(state, encoder: encoder, to: storage.stateURL, requireMissing: true)
        }
        committedState = state
        lastDiskDigest = initialDigest
        if let lastDiskDigest {
            backupPending = !FileManager.default.fileExists(atPath: storage.rootURL.appendingPathComponent("Recovery/latest-" + lastDiskDigest + ".json").path)
        }
        if pendingLegacyCredential != nil { indexNeedsRebuild = true; return }
        // Withdraw invalid original sources before displaying or rebuilding the archive.
        let loaded = state
        let invalid = Set(loaded.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let usable = Set(loaded.captures.filter {
            !loaded.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") && !invalid.contains($0.id)
        }.map(\.id))
        let referenced = Set(loaded.dailySummaries.flatMap(\.sourceCaptureIDs))
            .union(loaded.topicReviews.flatMap { $0.sourceVersions.keys })
            .union(loaded.weeklyReports.flatMap { $0.sourceIDs })
        state.invalidateMemoryOutputs(sourceIDs: referenced.subtracting(usable))
        state.reconcilePersonaProfile(recoveringInterrupted: true)
        if deferMaintenance {
            startupMaintenancePending = true
            indexNeedsRebuild = true
            return
        }
        var organizedState = state
        let knowledge = MemoryKnowledgeEngine().reconcile(organizedState)
        organizedState.applyReconciledKnowledge(knowledge)
        state = organizedState
        let migrationState = state
        for i in migrationState.weeklyReports.indices where migrationState.weeklyReports[i].isReadable {
            let report = migrationState.weeklyReports[i]
            if WeeklyReviewEngine.sourcesUnchanged(report, in: migrationState) {
                state.weeklyReports[i].sourceVersions = Dictionary(uniqueKeysWithValues: report.sourceIDs.compactMap { id in
                    WeeklyReviewEngine.sourceVersion(id: id, state: migrationState).map { (id, $0) }
                })
            }
        }
        lastDiskDigest = try Self.write(state, encoder: encoder, to: storage.stateURL, expectedDigest: lastDiskDigest)
        do { try intelligenceIndex?.replace(with: state) } catch { indexNeedsRebuild = true }
        committedState = state
        if let lastDiskDigest { backupPending = !FileManager.default.fileExists(atPath: storage.rootURL.appendingPathComponent("Recovery/latest-" + lastDiskDigest + ".json").path) }
    }

    /// Reads must not re-hash every recent review and its raw screenshots. Writes reconcile the profile.
    public func snapshot() -> RecallState { state }

    public func currentReviewSchedules() -> [ReviewSchedule] { state.reviewSchedules }

    public func conversationSnapshot() -> (id: UUID, state: RecallState) {
        (conversationID, state)
    }

    /// Snapshot and capture revision read in one actor call. 问一问 compares the revision later
    /// instead of re-reading every screenshot, which needs the two values to be consistent.
    public func conversationSnapshotWithRevision() -> (id: UUID, state: RecallState, captureRevision: UInt64) {
        (conversationID, state, captureContentRev)
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
        // 会话清空要同时落盘 sidecar 与主存档（后者含记忆与摘要的变更）；
        // 失败时把两边都还原。
        do {
            try persistConversation()
            try writeState()
        } catch {
            state = previous
            conversationID = previousID
            try? persistConversation()
            throw error
        }
        return result
    }

    public func saveMatterCorrection(_ correction: MatterCorrection) throws {
        let available = Set(state.captures.map(\.id))
        var correction = correction
        correction.evidenceIDs = correction.evidenceIDs.filter(available.contains)
        if correction.isTopicCompletion {
            guard !correction.evidenceIDs.isEmpty else { throw LLMError.serviceError("主题来源已变化，请更新记忆后重试。") }
            guard !state.matterCorrections.contains(where: {
                $0.isTopicCompletion && $0.topicID == correction.topicID && Set($0.evidenceIDs) == Set(correction.evidenceIDs)
            }) else { return }
            // Completion is a user-authored status overlay. Daily reviews and captured text
            // remain historical evidence; deleting them would force a fresh model analysis.
            state.matterCorrections.append(correction)
            state.topicReviews.removeAll { $0.id == correction.topicID }
            // 用户标记完成同时写入登记表，改名后也不会丢。
            if let topicID = correction.topicID, !state.topicRegistry.topics.isEmpty,
               let uuid = UUID(uuidString: String(topicID.dropFirst("topic:".count))),
               let topic = state.topicRegistry.topic(id: uuid) {
                var registry = state.topicRegistry
                var copy = topic; copy.manualLifecycle = .done; registry.upsert(copy)
                state.topicRegistry = registry
            }
            state.conversationSummary = nil
            state.conversationSummaryCoveredMessageCount = state.messages.count
            try persistReviewState()
            return
        }
        guard !correction.evidenceIDs.isEmpty else { return }
        state.pendingRecoveryCleanup = true
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
                    state.reminders[i].closedAt = correction.createdAt
                } else if state.reminders[i].origin == .discovered && state.reminders[i].status == .proposed {
                    state.reminders[i].status = .dismissed
                    state.reminders[i].closedAt = correction.createdAt
                }
                state.reminders[i].updatedAt = correction.createdAt
            }
        }
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
        try persist()
    }

    public func removeMatterCorrection(id: UUID) throws {
        if let correction = state.matterCorrections.first(where: { $0.id == id && $0.isTopicCompletion }) {
            state.matterCorrections.removeAll { $0.id == id }
            state.topicReviews.removeAll { $0.id == correction.topicID }
            if let topicID = correction.topicID,
               let uuid = UUID(uuidString: String(topicID.dropFirst("topic:".count))),
               let topic = state.topicRegistry.topic(id: uuid) {
                var registry = state.topicRegistry
                var copy = topic; copy.manualLifecycle = nil; registry.upsert(copy)
                state.topicRegistry = registry
            }
            state.conversationSummary = nil
            state.conversationSummaryCoveredMessageCount = state.messages.count
            try persistReviewState()
            return
        }
        let sourceIDs = Set(state.matterCorrections.filter { $0.id == id }.flatMap(\.evidenceIDs))
        invalidateMemoryOutputs(sourceIDs: sourceIDs)
        state.matterCorrections.removeAll { $0.id == id }
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = 0
        try persist()
    }

    public func setExperienceHints(enabled: Bool) throws {
        guard state.experienceHintsEnabled != enabled else { return }
        let previous = state
        state.experienceHintsEnabled = enabled
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = previous; throw error }
    }

    public func dismissExperience(id: String) throws {
        guard !id.isEmpty, !state.dismissedExperienceIDs.contains(id) else { return }
        let previous = state
        state.dismissedExperienceIDs.append(id)
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = previous; throw error }
    }

    public func isIntelligenceIndexAvailable() -> Bool { intelligenceIndex != nil }
    public func memoryIndexNeedsRebuild() -> Bool { indexNeedsRebuild || intelligenceIndex == nil }

    func finishStartupMaintenanceIfNeeded() {
        guard startupMaintenancePending else { return }
        state.migrateLegacyWeeklyVersions()
    }

    /// Reconcile a value copy on a worker. Actor reads and safety checks remain available
    /// throughout the slow work. A concurrent write makes this result obsolete, never authoritative.
    @discardableResult
    public func organizeMemoryInBackground(force: Bool = false, now: Date = .now, pruningExpired: Bool = false,
        onPreparing: (@Sendable () async -> Void)? = nil) async throws -> Bool {
        try Task.checkCancellation()
        guard !backgroundMaintenanceInFlight else { return false }
        backgroundMaintenanceInFlight = true
        defer { backgroundMaintenanceInFlight = false }
        let baseline = state, revision = archiveRevision, migrating = startupMaintenancePending
        let needsDerivation = force || migrating || lastMaintenanceRevision != revision || indexNeedsRebuild
            || !state.pendingDailyReviewMaintenance.isEmpty
        let prepared: RecallState? = try await LocalOperation.run(stage: "整理本地记忆", timeout: nil) {
            await onPreparing?()
            try Task.checkCancellation()
            var copy = baseline
            let pruned = pruningExpired ? try copy.pruneExpiredSources(now: now) : false
            guard needsDerivation || pruned else { return nil }
            if migrating { copy.migrateLegacyWeeklyVersions() }
            try Task.checkCancellation()
            if let id = copy.pendingDailyReviewMaintenance.first {
                copy.pendingDailyReviewMaintenance.removeFirst()
                if let summary = copy.dailySummaries.first(where: { $0.id == id }) { copy.projectDayFromMatters(summary.day) }
            }
            try copy.reconcileForPersistence(force: force, now: now, allowNew: true, cancellable: true)
            try Task.checkCancellation()
            return copy
        }
        try Task.checkCancellation()
        guard archiveRevision == revision else { return false }
        guard let prepared else { return true }
        state = prepared
        do { try persistReviewState(indexChanged: true); markStartupMaintenanceComplete() }
        catch { state = baseline; throw error }
        let indexedState = state, indexedRevision = archiveRevision, index = intelligenceIndex
        do {
            try await LocalOperation.run(stage: "更新本地索引", timeout: nil) {
                try Task.checkCancellation()
                try index?.replace(with: indexedState)
                try Task.checkCancellation()
            }
            indexNeedsRebuild = archiveRevision != indexedRevision || index == nil
            if !indexNeedsRebuild { lastMaintenanceRevision = archiveRevision }
        } catch {
            indexNeedsRebuild = true
            if ModelCallCancellation.isCancellation(error) { throw CancellationError() }
        }
        return true
    }

    func markStartupMaintenanceComplete() { startupMaintenancePending = false }

    /// Analysis view of the current memory. Recomputed after a memory write, not after each question.
    /// Messages are copied from the live session so a new question does not rebuild the ledger.
    public func preparedForChat() -> RecallState {
        var prepared: RecallState
        if let chatAnalysis {
            prepared = chatAnalysis
        } else {
            prepared = state.correctedForAnalysis()
            chatAnalysis = prepared
        }
        prepared.messages = state.messages
        prepared.conversationSummary = state.conversationSummary
        prepared.conversationSummaryCoveredMessageCount = state.conversationSummaryCoveredMessageCount
        prepared.llmConfiguration = state.llmConfiguration
        prepared.privacy = state.privacy
        guard !state.matterCorrections.isEmpty else { return prepared }
        let cutoff = state.matterCorrections.map(\.createdAt).max() ?? .distantPast
        let before = prepared.messages.count
        prepared.messages.removeAll { $0.createdAt <= cutoff }
        let removed = before - prepared.messages.count
        prepared.conversationSummaryCoveredMessageCount = max(0, (prepared.conversationSummaryCoveredMessageCount ?? 0) - removed)
        return prepared
    }

    public func indexedCaptureIDs(matching query: String, limit: Int = 12) -> [UUID] {
        guard !indexNeedsRebuild else { return [] }
        return (try? intelligenceIndex?.searchCaptureIDs(matching: query, limit: limit)) ?? []
    }

    /// Term index written when the screenshot text was saved. Nil when that index cannot be used yet.
    public func captureTextIndex() -> CaptureTextIndex? {
        guard let intelligenceIndex, !indexNeedsRebuild else { return nil }
        return CaptureTextIndex(index: intelligenceIndex)
    }

    public func updateRules(_ rules: [EventRule]) throws {
        state.rules = rules
        try persist()
    }

    public func updatePrivacy(_ privacy: PrivacySettings) throws {
        if state.privacy.excludedBundleIdentifiers != privacy.excludedBundleIdentifiers {
            let newlyExcluded = privacy.excludedBundleIdentifiers.subtracting(state.privacy.excludedBundleIdentifiers)
            let sources = Set(state.captures.filter { newlyExcluded.contains($0.sourceBundleIdentifier ?? "") }.map(\.id))
            invalidateMemoryOutputs(sourceIDs: sources)
            state.pendingRecoveryCleanup = true
        }
        state.privacy = privacy
        try persist()
    }

    public func updateLLMConfiguration(_ configuration: LLMConfiguration) throws {
        let before = state
        var config = configuration
        guard let origin = LLMConfiguration.credentialOrigin(config.baseURLString) else { throw LLMError.invalidBaseURL }
        var candidateCredentialID: UUID?
        if !config.apiKey.isEmpty {
            // Never overwrite the currently referenced Key. A failed state write, even with
            // a failed cleanup, cannot bind the new service's Key to the previous connection.
            let id = UUID()
            try credentials.write(config.apiKey, id: id)
            candidateCredentialID = id
            config.credentialReference = id.uuidString
            config.credentialRevision = max(config.credentialRevision, state.llmConfiguration.credentialRevision) + 1
        } else if config.isLocalEndpoint && origin != LLMConfiguration.credentialOrigin(state.llmConfiguration.baseURLString) {
            // A cloud key is never carried over to a local server: the reference is dropped, the key deleted after saving.
            config.credentialReference = nil
            config.credentialRevision = max(config.credentialRevision, state.llmConfiguration.credentialRevision) + 1
        } else if config.hasCredential && origin != LLMConfiguration.credentialOrigin(state.llmConfiguration.baseURLString) {
            throw CredentialError.endpointChanged
        }
        config.apiKey = ""; state.llmConfiguration = config
        reconcileDailyReviewCheckpoints()
        do { try persistReviewState() }
        catch {
            state = before
            if let candidateCredentialID { try? credentials.delete(candidateCredentialID) }
            throw error
        }
        if candidateCredentialID != nil || (config.credentialReference == nil && before.llmConfiguration.credentialReference != nil),
           before.llmConfiguration.credentialReference != nil,
           before.llmConfiguration.credentialID != config.credentialID || config.credentialReference == nil {
            try? credentials.delete(before.llmConfiguration.credentialID)
        }
    }
    static func scrubLegacyBackups(in root: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("recall-state.backup-") && url.pathExtension == "json" {
            guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  var config = json["llmConfiguration"] as? [String: Any], config["apiKey"] != nil else { continue }
            config.removeValue(forKey: "apiKey"); json["llmConfiguration"] = config
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url, options: .atomic)
        }
    }

    private func invalidateWeeklyReports() { state.invalidateWeeklyReports() }

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

    public func saveTopicGroup(_ group: MemoryTopicGroup) throws {
        guard group.memberIDs.count >= 2, !group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !state.topicGroups.contains(where: { !Set($0.memberIDs).isDisjoint(with: group.memberIDs) }) else { throw WeeklyReviewError.changedSources }
        let files = MatterMemoryEngine().files(in: state)
        guard Set(group.memberIDs).isSubset(of: Set(files.map(\.id))) else { throw WeeklyReviewError.changedSources }
        let index = ReviewCategoryIndex(state: state)
        let categories = Set(files.filter { group.memberIDs.contains($0.id) }.map { index.category(for: $0) }.filter { $0 != .unclassified })
        guard categories.count <= 1 else { throw WeeklyReviewError.noWorkScope }
        let before = state
        var group = group
        group.sourceIDs = files.filter { group.memberIDs.contains($0.id) }.flatMap(\.evidenceIDs)
        // 合并后把成员旧键写成别名：以后模型换个叫法，新记录仍归到同一主题。
        let canonical = files.filter { group.memberIDs.contains($0.id) }
            .max { $0.evidenceIDs.count == $1.evidenceIDs.count ? $0.id > $1.id : $0.evidenceIDs.count < $1.evidenceIDs.count }
            .map { DailyKnowledgeEngine.topicKey($0.title) }
        if let canonical {
            for member in group.memberIDs where member.hasPrefix("topic:") {
                let key = String(member.dropFirst("topic:".count))
                if key != canonical { state.topicAliases[key] = canonical }
            }
        }
        state.topicGroups.append(group)
        invalidateGroupedReports(Set(group.memberIDs))
        do { try persist() } catch { state = before; throw error }
    }
    /// 写入主题别名（旧键 → 规范键）。合并主题时自动调用，也用于迁移。
    public func saveTopicAliases(_ aliases: [String: String]) throws {
        let merged = aliases.filter { $0.key != $0.value && state.topicAliases[$0.key] != $0.value }
        guard !merged.isEmpty else { return }
        let before = state
        for (old, canonical) in merged { state.topicAliases[old] = canonical }
        do { try persist() } catch { state = before; throw error }
    }

    /// 删除主题：登记表条目、别名、主题小结、完成标记、合并组成员一并清除；
    /// 原始记录与截图不删除，仍可在时间线回看。
    public func deleteTopic(id: String) throws {
        guard !state.topicRegistry.topics.isEmpty || state.topicReviews.contains(where: { $0.id == id }) else { return }
        let before = state
        let canonical = state.topicRegistry.canonicalID(id)
        let uuid = canonical.hasPrefix("topic:") ? UUID(uuidString: String(canonical.dropFirst("topic:".count))) : nil
        if let uuid, state.topicRegistry.topic(id: uuid) != nil {
            var registry = state.topicRegistry
            registry.remove(id: uuid)
            state.topicRegistry = registry
        }
        // 闭包里读 state 会和 removeAll 的写冲突，先把登记表取出来。
        let registry = state.topicRegistry
        state.topicReviews.removeAll { registry.canonicalID($0.id) == canonical }
        state.matterCorrections.removeAll { registry.canonicalID($0.topicID ?? "") == canonical }
        for index in state.topicGroups.indices {
            state.topicGroups[index].memberIDs.removeAll { registry.canonicalID($0) == canonical }
        }
        state.topicGroups.removeAll { $0.memberIDs.count < 2 }
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = state.messages.count
        try? deleteSession(topicID: id)
        do { try persistReviewState() } catch { state = before; throw error }
    }

    /// 新建项目（只是分组容器，没有自己的事件）。
    @discardableResult
    public func createProject(title: String) throws -> Topic? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let before = state
        var registry = state.topicRegistry
        let project = Topic(title: name, isProject: true)
        registry.upsert(project)
        state.topicRegistry = registry
        do { try persist() } catch { state = before; throw error }
        return project
    }

    /// 设置主题所属项目；parentID 传 nil 表示移出项目。
    public func setTopicParent(topicID: String, parentID: String?) throws {
        let canonical = state.topicRegistry.canonicalID(topicID)
        guard let id = UUID(uuidString: canonical.hasPrefix("topic:") ? String(canonical.dropFirst("topic:".count)) : canonical) else { return }
        let parentUUID = parentID.flatMap { parent -> UUID? in
            let value = state.topicRegistry.canonicalID(parent)
            return UUID(uuidString: value.hasPrefix("topic:") ? String(value.dropFirst("topic:".count)) : value)
        }
        let before = state
        var registry = state.topicRegistry
        guard registry.setParent(parentUUID, of: id) else { throw WeeklyReviewError.changedSources }
        state.topicRegistry = registry
        do { try persist() } catch { state = before; throw error }
    }

    /// 删除项目：子主题回到顶层，不删除主题本身。
    public func deleteProject(id: String) throws {
        let value = state.topicRegistry.canonicalID(id)
        guard let uuid = UUID(uuidString: value.hasPrefix("topic:") ? String(value.dropFirst("topic:".count)) : value),
              state.topicRegistry.topic(id: uuid) != nil else { return }
        let before = state
        var registry = state.topicRegistry
        registry.deleteProject(id: uuid)
        state.topicRegistry = registry
        do { try persist() } catch { state = before; throw error }
    }

    public func undoTopicGroup(_ id: String) throws {
        guard let group = state.topicGroups.first(where: { $0.id == id }) else { return }
        let before = state
        state.topicGroups.removeAll { $0.id == id }
        let keys = Set(group.memberIDs.map { $0.hasPrefix("topic:") ? String($0.dropFirst("topic:".count)) : $0 })
        let staleAliases = state.topicAliases.filter { keys.contains($0.key) && keys.contains($0.value) }.map(\.key)
        for key in staleAliases { state.topicAliases.removeValue(forKey: key) }
        invalidateGroupedReports(Set(group.memberIDs + [id]))
        do { try persist() } catch { state = before; throw error }
    }
    private func invalidateGroupedReports(_ ids: Set<String>) {
        for i in state.weeklyReports.indices where state.weeklyReports[i].items.contains(where: { ids.contains($0.id) }) { state.weeklyReports[i].invalidate() }
        for i in state.recentlyDeletedMemories.indices {
            guard var reports = state.recentlyDeletedMemories[i].weeklyReports else { continue }
            for j in reports.indices where reports[j].items.contains(where: { ids.contains($0.id) }) { reports[j].invalidate() }
            state.recentlyDeletedMemories[i].weeklyReports = reports
        }
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
        guard old != value || value.nextRunAt == nil else { return }
        value.nextRunAt = value.nextTrigger(after: now); value.retryAfter = nil
        value.failureCount = 0; value.lastReportID = nil
        state.reviewSchedules.removeAll { $0.id == value.id }; state.reviewSchedules.append(value)
        // The plan is a few hundred bytes. Rewriting the capture archive here blocks the save button
        // for as long as it takes to encode and copy every stored record.
        do { try writeReviewScheduleSidecar() } catch { state = before; throw error }
    }

    public func deleteReviewSchedule(id: UUID) throws {
        guard state.reviewSchedules.contains(where: { $0.id == id }) else { return }
        let before = state
        state.reviewSchedules.removeAll { $0.id == id }
        do { try writeReviewScheduleSidecar() } catch { state = before; throw error }
    }

    public func commitWeeklyReport(_ submitted: WeeklyReport, replacing id: UUID? = nil,
                                   schedule expected: ReviewSchedule? = nil, categories: [String: ReviewCategory]? = nil,
                                   now: Date = .now) throws -> WeeklyReport {
        try commitWeeklyReportMeasured(submitted, replacing: id, schedule: expected, categories: categories, now: now).report
    }

    public func commitWeeklyReportMeasured(_ submitted: WeeklyReport, replacing id: UUID? = nil,
                                          schedule expected: ReviewSchedule? = nil, categories: [String: ReviewCategory]? = nil,
                                          now: Date = .now) throws -> (report: WeeklyReport, metrics: WeeklyReviewSaveMetrics) {
        let started = Date.now
        try Task.checkCancellation()
        guard state.weeklyReports.contains(where: { $0.id == submitted.id })
                || !state.recentlyDeletedMemories.contains(where: { $0.weeklyReports?.contains(where: { $0.id == submitted.id }) == true }) else {
            throw WeeklyReviewError.changedSources
        }
        guard submitted.feedbackRevision == nil || submitted.feedbackRevision == SummaryFeedbackLearning.revision(in: state) else { throw WeeklyReviewError.changedSources }
        guard WeeklyReviewEngine.sourcesUnchanged(submitted, in: state),
              categories == nil || categories == state.reviewCategories else { throw WeeklyReviewError.changedSources }
        if let expected {
            guard state.reviewSchedules.contains(expected), expected.isDue(at: now),
                  let trigger = submitted.scheduledFor ?? expected.effectiveTrigger(at: now),
                  submitted.period == expected.period(at: trigger),
                  submitted.template == expected.template, submitted.scope == expected.scope else { throw WeeklyReviewError.changedSources }
        }
        let sourceCheckMs = Int(Date.now.timeIntervalSince(started) * 1000)
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
        // Saving a derived report changes no original source or understanding. Its dependencies
        // were checked above; avoid reconciling every historical report and the entire archive again.
        let written: ArchiveWriteMetrics
        do { try Task.checkCancellation(); written = try persistReviewStateMeasured() } catch { state = before; throw error }
        return (report, WeeklyReviewSaveMetrics(sourceCheckMilliseconds: sourceCheckMs,
            encodeMilliseconds: written.encodeMilliseconds, writeMilliseconds: written.writeMilliseconds,
            archiveBytes: written.bytes, totalMilliseconds: Int(Date.now.timeIntervalSince(started) * 1000)))
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
        forgetSummaryFeedback(reportID: id)
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
        syncTopicRegistry(for: summary)
        try persist()
    }

    /// 每日回顾写入后补齐登记表：新主题登记、已有主题刷新最近活动时间。
    /// 只记录名字与时间，不含原文。
    func syncTopicRegistry(for summary: DailySummary) {
        var registry = state.topicRegistry
        for item in summary.items {
            guard let knowledge = item.knowledge, knowledge.kind == .matter, knowledge.ownedByUser,
                  let name = knowledge.topic?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            var topic: Topic
            if let id = knowledge.topicID, let existing = registry.topic(id: id) { topic = existing }
            else { topic = registry.resolveOrCreate(name: name, at: summary.day) }
            if (topic.lastEventAt ?? .distantPast) < summary.day { topic.lastEventAt = summary.day }
            registry.upsert(topic)
        }
        state.topicRegistry = registry
    }

    public func applyIntelligence(_ consolidation: IntelligenceConsolidation, for day: Date) throws {
        applyIntelligenceState(consolidation, for: day)
        try persist()
    }

    public func commitDailySummary(_ submitted: DailySummary, consolidation: IntelligenceConsolidation) throws {
        try Task.checkCancellation()
        let before = state
        var summary = submitted
        if let old = state.dailySummaries.first(where: { Calendar.current.isDate($0.day, inSameDayAs: summary.day) }) {
            summary.versions = Array(([DailyReviewVersion(summary: old)] + (old.versions ?? [])).prefix(8))
            summary.sourceCaptureIDs = Array(Set(summary.sourceCaptureIDs + (summary.versions ?? []).flatMap(\.sourceIDs)))
        }
        state.dailySummaries.removeAll { Calendar.current.isDate($0.day, inSameDayAs: summary.day) }
        state.dailySummaries.append(summary)
        state.dailySummaries.sort { $0.day > $1.day }
        syncTopicRegistry(for: summary)
        applyIntelligenceState(consolidation, for: summary.day)
        do { try Task.checkCancellation(); try persist() } catch { state = before; throw error }
    }

    /// Updates one day's episodes and the projects touched that day. Other days' projects, user memories and routines stay.
    func projectDayFromMatters(_ day: Date) { state.projectDayFromMatters(day) }

    func applyIntelligenceState(_ consolidation: IntelligenceConsolidation, for day: Date) {
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
        forgetSummaryFeedback(reportID: id)
        invalidateMemoryOutputs(sourceIDs: [id])
        state.dailySummaries.removeAll { $0.id == id }
        state.pendingPersonaRefresh.removeAll { $0 == id }
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
        let removedReminders = state.reminders.filter { $0.status != .planned && $0.origin != .manual && !$0.sourceCaptureIDs.filter(actualIDs.contains).isEmpty }
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
        var knowledgeSnapshot = MemoryKnowledge()
        knowledgeSnapshot.claims = state.memoryKnowledge.claims.filter { !Set($0.sourceIDs).isDisjoint(with: actualIDs) }
        knowledgeSnapshot.entities = state.memoryKnowledge.entities.filter { !Set($0.sourceIDs).isDisjoint(with: actualIDs) }
        let affectedKeys = Set(knowledgeSnapshot.claims.map(\.key))
        knowledgeSnapshot.suppressedKeys = state.memoryKnowledge.suppressedKeys.filter(affectedKeys.contains)
        let meetingIDs = Set(removedCaptures.compactMap(\.meetingSessionID)).filter { id in
            state.captures.filter { $0.meetingSessionID == id }.allSatisfy { actualIDs.contains($0.id) }
        }
        transaction.meetingSessions = state.workflow.meetings.filter { meetingIDs.contains($0.id) }
        state.workflow.meetings.removeAll { meetingIDs.contains($0.id) }
        transaction.memoryKnowledge = knowledgeSnapshot
        transaction.weeklyReports = state.weeklyReports.filter { !$0.sourceIDs.isDisjoint(with: actualIDs) }
        transaction.topicReviews = state.topicReviews.filter { !Set($0.sourceVersions.keys).isDisjoint(with: actualIDs) }
        transaction.topicGroups = state.topicGroups.filter { !Set($0.sourceIDs ?? []).isDisjoint(with: actualIDs) }
        transaction.matterCorrections = state.matterCorrections.filter { !Set($0.evidenceIDs).isDisjoint(with: actualIDs) }
        state.matterCorrections.removeAll { !Set($0.evidenceIDs).isDisjoint(with: actualIDs) }
        state.captures.removeAll { actualIDs.contains($0.id) }
        state.dailySummaries.removeAll { summary in removedSummaries.contains(where: { $0.id == summary.id }) }
        state.messages.removeAll { message in removedMessages.contains(where: { $0.id == message.id }) }
        for i in state.reminders.indices where state.reminders[i].status == .planned && !Set(state.reminders[i].sourceCaptureIDs).isDisjoint(with: actualIDs) {
            state.reminders[i].sourceCaptureIDs.removeAll { actualIDs.contains($0) }
            state.reminders[i].analysis = nil
        }
        state.reminders.removeAll { reminder in removedReminders.contains(where: { $0.id == reminder.id }) }
        state.reminderLearningProfile.removeHistorySources(actualIDs)
        state.episodes.removeAll { episode in removedEpisodes.contains(where: { $0.id == episode.id }) }
        state.projects = state.projects.compactMap { project in
            guard actualIDs.contains(where: project.evidenceIDs.contains) else { return project }
            return nil
        }
        state.userMemories.removeAll { memory in removedMemories.contains(where: { $0.id == memory.id }) }
        state.insights.removeAll { insight in removedInsights.contains(where: { $0.id == insight.id }) }
        state.insightFeedback.removeAll { removedInsightIDs.contains($0.insightID) }
        state.learnedRoutines.removeAll { routine in removedRoutines.contains(where: { $0.id == routine.id }) }
        for day in days { projectDayFromMatters(day) }
        for id in actualIDs { state.reminderDiscoveryCheckpoint.processedCaptureHashes.removeValue(forKey: id.uuidString) }
        state.conversationSummary = nil
        state.conversationSummaryCoveredMessageCount = 0
        state.recentlyDeletedMemories.insert(transaction, at: 0)
        state.pendingRecoveryCleanup = true
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
        forgetSummaryFeedback(reportID: id)
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
        state.dailySummaries[index].modelOverview = nil
        state.dailySummaries[index].content = state.dailySummaries[index].modelCoverage == nil
            ? DailySummaryItemParser.markdown(from: state.dailySummaries[index].items)
            : DailySummaryItemParser.reviewedMarkdown(from: state.dailySummaries[index].items)
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
        let groupedMembers = Set(state.topicGroups.flatMap(\.memberIDs))
        let restoredGroups = (transaction.topicGroups ?? []).filter { Set($0.memberIDs).isDisjoint(with: groupedMembers) }
        Self.restoreUnique(restoredGroups, to: &state.topicGroups, id: \.id)
        Self.restoreUnique(transaction.weeklyReports ?? [], to: &state.weeklyReports, id: \.id)
        Self.restoreUnique(transaction.topicReviews ?? [], to: &state.topicReviews, id: \.id)
        Self.restoreUnique(transaction.messages, to: &state.messages, id: \.id)
        state.messages.sort { $0.createdAt < $1.createdAt }
        Self.restoreUnique(transaction.reminders, to: &state.reminders, id: \.id)
        Self.restoreUnique(transaction.meetingSessions ?? [], to: &state.workflow.meetings, id: \.id)
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
        if let knowledge = transaction.memoryKnowledge {
            Self.restoreUnique(knowledge.claims, to: &state.memoryKnowledge.claims, id: \.id)
            let currentEntityIDs = Set(state.memoryKnowledge.entities.map(\.id))
            state.memoryKnowledge.entities += knowledge.entities.filter { !currentEntityIDs.contains($0.id) }
            state.memoryKnowledge.suppressedKeys = (state.memoryKnowledge.suppressedKeys + knowledge.suppressedKeys).memoryUnique()
        }
        if !transaction.captures.isEmpty { applyKnowledge(MemoryKnowledgeEngine().reconcile(state, force: true)) }
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
        let before = state
        queueDeletedScreenshots(item.screenshotPaths)
        state.pendingRecoveryCleanup = true
        state.recentlyDeletedMemories.removeAll { $0.id == id }
        do { try persist() } catch { state = before; throw error }
        _ = try retryPendingFileCleanup()
    }

    @discardableResult
    public func purgeExpiredRecentlyDeleted(now: Date = .now) throws -> Int {
        let expired = state.recentlyDeletedMemories.filter { $0.expiresAt <= now }
        guard !expired.isEmpty else { return 0 }
        let before = state
        queueDeletedScreenshots(expired.flatMap(\.screenshotPaths))
        state.pendingRecoveryCleanup = true
        let ids = Set(expired.map(\.id))
        state.recentlyDeletedMemories.removeAll { ids.contains($0.id) }
        do { try persist() } catch { state = before; throw error }
        _ = try retryPendingFileCleanup()
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
        for id in state.dailySummaries.map(\.id) { forgetSummaryFeedback(reportID: id) }
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
        let before = state
        let activePaths = (state.captures.compactMap(\.imageRelativePath) + state.memoryKnowledge.pendingScreenshotDeletions).memoryUnique()
        let deletedPaths = state.recentlyDeletedMemories.flatMap(\.screenshotPaths)
        state.dataGeneration = UUID()
        state.captures = []
        state.messages = []
        state.reminders = []
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
        state.reminderLearningProfile = ReminderLearningProfile()
        state.dailySummaries = []
        state.weeklyReports = []
        state.reviewCategories = [:]
        state.topicGroups = []
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
        state.summaryFeedback = []
        state.understandingJobs = []
        state.dismissedExperienceIDs = []
        state.workflow.meetings = []
        state.topicReviews = []
        state.dailyReviewCheckpoints = []
        state.pendingDailyReviewMaintenance = []
        state.dailyReviewAttemptedDays = []
        state.pendingPersonaRefresh = []
        state.personaTraitObservations = []
        state.personaTraits = []
        state.dismissedPersonaDimensions = []
        state.personaRefreshJobs = []; state.personaProfileRevision = UUID()
        state.rejectedPersonaEvidence = []
        state.pendingFileDeletions = ((state.pendingFileDeletions ?? []) + activePaths + deletedPaths.map { "Recently Deleted/Screenshots/" + URL(fileURLWithPath: $0).lastPathComponent } + managedScreenshotFiles()).memoryUnique()
        state.pendingRecoveryCleanup = true
        do { try persist() } catch { state = before; throw error }
        conversationID = UUID()
        _ = try retryPendingFileCleanup()
    }

    public func updateConversationSummary(_ summary: String?, coveredMessageCount: Int, inConversation expectedID: UUID? = nil) throws {
        if expectedID != nil { try Task.checkCancellation() }
        if let expectedID, expectedID != conversationID { throw CancellationError() }
        state.conversationSummary = summary
        state.conversationSummaryCoveredMessageCount = coveredMessageCount
        try persistReviewState(invalidateAnalysis: false)
    }

    public func addCapture(_ capture: CaptureRecord) throws {
        let before = state
        state.captures.insert(capture, at: 0)
        do { try persistAppended() } catch { state = before; throw error }
    }

    /// A new capture cannot change an existing source version, so existing reviews, feedback and
    /// understanding stay valid. The whole-archive reconciliation in `persist()` runs on the
    /// maintenance cycle (`organizeMemory`) instead of blocking every recording.
    private func persistAppended() throws {
        chatAnalysis = nil
        guard pendingLegacyCredential == nil else { throw CredentialError.unavailable }
        try writeState()
        guard !indexNeedsRebuild else { return }
        do { try intelligenceIndex?.synchronize(with: state) } catch { indexNeedsRebuild = true }
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
        let before = state
        guard let removed = removeCaptureState(id: id) else { return nil }
        state.pendingFileDeletions = ((state.pendingFileDeletions ?? []) + [removed.imageRelativePath].compactMap { $0 }).memoryUnique()
        state.pendingRecoveryCleanup = true
        do { try persist() } catch { state = before; throw error }
        _ = try retryPendingFileCleanup()
        return removed
    }

    private func removeCaptureState(id: UUID) -> CaptureRecord? { state.removeCaptureState(id: id) }

    /// 会话消息单独写盘；不再重启整份存档的编码。
    /// 凭据迁移未完成时整份存档只读，这里同样要拦住，否则消息会在只读状态下落盘。
    private func persistConversation() throws {
        try Task.checkCancellation()
        guard pendingLegacyCredential == nil else { throw CredentialError.unavailable }
        conversationArchive.scopes[conversationArchive.activeScope]?.messages = state.messages
        conversationArchive.scopes[conversationArchive.activeScope]?.updatedAt = .now
        if conversationArchive.scopes[conversationArchive.activeScope] == nil {
            conversationArchive.scopes[conversationArchive.activeScope] = .init(messages: state.messages)
        }
        let data = try encoder.encode(conversationArchive)
        try data.write(to: storage.conversationURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storage.conversationURL.path)
    }

    /// 切到某个作用域的会话：全局传 nil，主题传主题 ID。消息互不相通。
    public func activateSession(topicID: String?) throws {
        let scope = topicID.map(ConversationArchive.topicScope) ?? ConversationArchive.globalScope
        guard scope != conversationArchive.activeScope else { return }
        let previousMessages = state.messages
        do { try persistConversation() }
        catch {
            state.messages = previousMessages
            throw error
        }
        conversationArchive.activeScope = scope
        if conversationArchive.scopes[scope] == nil { conversationArchive.scopes[scope] = .init() }
        state.messages = conversationArchive.scopes[scope]?.messages ?? []
        // 在途回答不应再写进新切换的会话。
        conversationID = UUID()
        try persistConversation()
    }

    /// 删除某个作用域的会话（删除主题时联动）。
    public func deleteSession(topicID: String) throws {
        let scope = ConversationArchive.topicScope(topicID)
        guard conversationArchive.scopes.removeValue(forKey: scope) != nil else { return }
        if conversationArchive.activeScope == scope {
            conversationArchive.activeScope = ConversationArchive.globalScope
            if conversationArchive.scopes[ConversationArchive.globalScope] == nil {
                conversationArchive.scopes[ConversationArchive.globalScope] = .init()
            }
            state.messages = conversationArchive.scopes[ConversationArchive.globalScope]?.messages ?? []
            conversationID = UUID()
        }
        try persistConversation()
    }

    /// 当前会话上一轮回答引用的来源，追问时优先作为候选。
    public func lastCitedSourceIDs() -> [UUID] {
        conversationArchive.scopes[conversationArchive.activeScope]?.lastCitedSourceIDs ?? []
    }

    /// 只写回答案所属的会话：发起后被切走或清空的答案不再改任何会话。
    public func recordAnswerCitations(_ ids: [UUID], inConversation expectedID: UUID, topicID: String?) {
        let scope = topicID.map(ConversationArchive.topicScope) ?? ConversationArchive.globalScope
        guard expectedID == conversationID, scope == conversationArchive.activeScope,
              conversationArchive.scopes[scope] != nil else { return }
        conversationArchive.scopes[scope]?.lastCitedSourceIDs = ids
    }

    func addAnswer(_ message: ConversationMessage, inConversation expectedID: UUID, topicID: String?) throws {
        try Task.checkCancellation()
        guard expectedID == conversationID else { throw CancellationError() }
        let previous = conversationArchive
        recordAnswerCitations(message.citations, inConversation: expectedID, topicID: topicID)
        do { try addMessage(message, inConversation: expectedID) }
        catch { conversationArchive = previous; throw error }
    }

    public func addMessage(_ message: ConversationMessage, inConversation expectedID: UUID? = nil) throws {
        if expectedID != nil { try Task.checkCancellation() }
        if let expectedID, expectedID != conversationID { throw CancellationError() }
        let before = state
        var message = message
        if message.role == .assistant {
            message.sourceVersions = Dictionary(uniqueKeysWithValues: message.citations.compactMap { id in
                state.captures.first(where: { $0.id == id }).map { (id.uuidString, CaptureUnderstandingEngine.sourceVersion($0, in: state)) }
            })
        }
        state.messages.append(message)
        do { try persistConversation() } catch { state = before; throw error }
    }

    public func rateMessage(id: UUID, helpful: Bool?) throws {
        guard let index = state.messages.firstIndex(where: { $0.id == id && $0.role == .assistant }) else { return }
        let previous = state
        do { state.messages[index].helpful = helpful; try persistConversation() }
        catch { state = previous; throw error }
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
        let previous = state
        if let index = state.reminders.firstIndex(where: { $0.id == reminder.id }) {
            state.reminders[index] = reminder
        } else {
            state.reminders.insert(reminder, at: 0)
        }
        do {
            if reminder.origin == .manual && reminder.sourceCaptureIDs.isEmpty {
                try persistReviewState()
            } else { try persist() }
        } catch { state = previous; throw error }
    }

    /// 将提醒状态与用户反馈一次写入，避免只保存了其中一部分。
    public func updateReminder(
        _ reminder: ReminderCandidate,
        learningProfile: ReminderLearningProfile
    ) throws {
        try saveReminder(reminder, learningProfile: learningProfile, isCompletion: false)
    }

    public func completeReminder(_ original: ReminderCandidate, updated: ReminderCandidate, semanticKey: String) throws {
        guard updated.id == original.id, state.reminders.contains(original),
              original.status == .planned || original.status.needsNotification else {
            throw DailyReviewActionError.changed
        }
        var profile = state.reminderLearningProfile
        profile.record(.completed, semanticKey: semanticKey)
        try saveReminder(updated, learningProfile: profile, isCompletion: true)
    }

    private func saveReminder(_ reminder: ReminderCandidate, learningProfile: ReminderLearningProfile, isCompletion: Bool) throws {
        let previous = state
        if let index = state.reminders.firstIndex(where: { $0.id == reminder.id }) {
            state.reminders[index] = reminder
        } else {
            state.reminders.insert(reminder, at: 0)
        }
        state.reminderLearningProfile = learningProfile
        for i in state.dailySummaries.indices {
            for j in state.dailySummaries[i].todos.indices {
                let action = state.dailySummaries[i].todos[j]
                guard action.id == reminder.id || (action.title == reminder.title && !Set(action.sourceCaptureIDs).isDisjoint(with: reminder.sourceCaptureIDs)) else { continue }
                if reminder.status == .completed { state.dailySummaries[i].todos[j].status = .completed }
                if reminder.status == .cancelled || reminder.status == .dismissed { state.dailySummaries[i].todos[j].status = .ignored }
            }
        }
        do {
            if isCompletion {
                try persistReviewState(indexChanged: true)
            } else if reminder.origin == .manual && reminder.sourceCaptureIDs.isEmpty {
                try persistReviewState()
            } else { try persist() }
        } catch { state = previous; throw error }
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
            updated.closedAt = updated.updatedAt
            let semanticKey = reminder.semanticKey.isEmpty
                ? String(reminder.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).filter { $0.isLetter || $0.isNumber })
                : reminder.semanticKey
            learningProfile.record(.dismissed, semanticKey: semanticKey)
            dismissedCount += 1
            return updated
        }
        guard dismissedCount > 0 else { return 0 }
        state.reminderLearningProfile = learningProfile
        let dismissedIDs = Set(state.reminders.filter { $0.status == .dismissed }.map(\.id))
        for i in state.dailySummaries.indices {
            for j in state.dailySummaries[i].todos.indices where dismissedIDs.contains(state.dailySummaries[i].todos[j].id) {
                state.dailySummaries[i].todos[j].status = .ignored
            }
        }
        try persist()
        return dismissedCount
    }

    public func clearReminderData() throws {
        state.reminders = []
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
        state.reminderLearningProfile = ReminderLearningProfile()
        try persist()
    }

    /// New captures are inserted at index 0, so a 12-second window only needs the newest records.
    public func hasRecentHash(_ hash: String, within seconds: TimeInterval = 12, now: Date = .now) -> Bool {
        state.captures.prefix(Self.recentCaptureWindow).contains { record in
            record.contentHash == hash && now.timeIntervalSince(record.createdAt) <= seconds
        }
    }

    /// Consecutive screenshots of the same screen differ by a clock tick or cursor, so an exact hash
    /// misses them. A capture from the same app within the window whose lines are almost all already
    /// recorded adds nothing but duplicate evidence.
    public func hasRecentNearDuplicate(text: String, bundleIdentifier: String?, within seconds: TimeInterval = 12,
                                       threshold: Double = 0.9, now: Date = .now) -> Bool {
        let lines = CaptureTextFingerprint.lines(text)
        guard lines.count >= 4 else { return false }
        return state.captures.prefix(Self.recentCaptureWindow).contains { record in
            guard now.timeIntervalSince(record.createdAt) <= seconds, record.eventTemplate != .dailyReview,
                  record.sourceBundleIdentifier == bundleIdentifier else { return false }
            let other = CaptureTextFingerprint.lines(record.ocrText)
            guard !other.isEmpty else { return false }
            return Double(lines.intersection(other).count) / Double(lines.count) >= threshold
        }
    }
    private static let recentCaptureWindow = 64

    public func prune(now: Date = .now) throws -> [String] {
        let previous = state
        var copy = state
        guard try copy.pruneExpiredSources(now: now) else { return state.memoryKnowledge.pendingScreenshotDeletions }
        state = copy
        do { try persist() } catch { state = previous; throw error }
        return state.memoryKnowledge.pendingScreenshotDeletions
    }

    func persist(preservingReviewsFrom previous: RecallState? = nil) throws {
        do {
            chatAnalysis = nil
            guard pendingLegacyCredential == nil else { throw CredentialError.unavailable }
            try state.reconcileForPersistence()
            if let previous { preserveReviewHistory(from: previous) }
            try writeState()
            // A full rebuild took ~70 s here and held every caller, including a question, behind it. Leave it to
            // the background organize step, which rebuilds off this actor; lookups use the in-memory path meanwhile.
            if !indexNeedsRebuild {
                do { try intelligenceIndex?.synchronize(with: state) } catch { indexNeedsRebuild = true }
            }
        } catch {
            if let committedState { state = committedState }
            chatAnalysis = nil
            throw error
        }
    }

    /// Only review-owned fields changed. Full reconciliation/index maintenance follows
    /// on the existing maintenance cycle; queries use their memory fallback meanwhile.
    func persistReviewState(indexChanged: Bool = false, invalidateAnalysis: Bool = true) throws {
        _ = try persistReviewStateMeasured(indexChanged: indexChanged, invalidateAnalysis: invalidateAnalysis)
    }

    private func persistReviewStateMeasured(indexChanged: Bool = false, invalidateAnalysis: Bool = true) throws -> ArchiveWriteMetrics {
        do {
            if invalidateAnalysis { chatAnalysis = nil }
            guard pendingLegacyCredential == nil else { throw CredentialError.unavailable }
            try Task.checkCancellation()
            let metrics = try writeState()
            if indexChanged { indexNeedsRebuild = true }
            return metrics
        } catch {
            if let committedState { state = committedState }
            chatAnalysis = nil
            throw error
        }
    }

    @discardableResult
    private static func withoutMessages(_ state: RecallState) -> RecallState {
        var copy = state
        copy.messages = []
        return copy
    }

    private static func write(_ state: RecallState, encoder: JSONEncoder, to url: URL, expectedDigest: String? = nil, requireMissing: Bool = false) throws -> String {
        let data = try encoder.encode(Self.withoutMessages(state))
        _ = try ArchiveReliability.write(data, storage: RecallStorage(rootURL: url.deletingLastPathComponent()), expectedDigest: expectedDigest, requireMissing: requireMissing)
        return ArchiveReliability.digest(data)
    }

    /// A newer sidecar wins on the next launch. A full archive write is newer than the sidecar, so its copy is used instead.
    private static func overlayNewerReviewSchedules(_ state: inout RecallState, storage: RecallStorage, decoder: JSONDecoder) {
        let sidecar = storage.reviewSchedulesURL
        guard FileManager.default.fileExists(atPath: sidecar.path),
              let sideDate = try? sidecar.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let mainDate = try? storage.stateURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              sideDate >= mainDate,
              let data = try? Data(contentsOf: sidecar),
              let saved = try? decoder.decode(ReviewScheduleSidecar.self, from: data) else { return }
        state.reviewSchedules = saved.reviewSchedules
    }

    private func writeReviewScheduleSidecar() throws {
        chatAnalysis = nil
        let data = try encoder.encode(ReviewScheduleSidecar(reviewSchedules: state.reviewSchedules))
        let url = storage.reviewSchedulesURL
        try ArchiveReliability.exclusive(storage) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        archiveRevision &+= 1
    }

    @discardableResult
    private func writeState() throws -> ArchiveWriteMetrics {
        do {
            state.reconcilePersonaProfile()
            refreshCaptureRevision()
            let started = Date.now
            // 消息在 conversation.json 里，主存档不带，避免每条消息重写整份 OCR。
            let data = try encoder.encode(Self.withoutMessages(state))
            let encodeMs = Int(Date.now.timeIntervalSince(started) * 1000)
            let writing = Date.now
            backupPending = try !ArchiveReliability.write(data, storage: storage, expectedDigest: lastDiskDigest)
            lastDiskDigest = ArchiveReliability.digest(data)
            committedState = state
            archiveRevision &+= 1
            return ArchiveWriteMetrics(encodeMilliseconds: encodeMs, writeMilliseconds: Int(Date.now.timeIntervalSince(writing) * 1000), bytes: data.count)
        } catch {
            if let committedState { state = committedState }
            if let lastDiskDigest { backupPending = !FileManager.default.fileExists(atPath: storage.rootURL.appendingPathComponent("Recovery/latest-" + lastDiskDigest + ".json").path) }
            chatAnalysis = nil; indexNeedsRebuild = true
            throw error
        }
    }
}


enum CaptureTextFingerprint {
    /// Normalized, order-independent set of meaningful lines.
    static func lines(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return line.count >= 4 ? line : nil
        })
    }
    static func normalized(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
