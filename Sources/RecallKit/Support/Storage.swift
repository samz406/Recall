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

    public init(fileManager: FileManager = .default) throws {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecallStorageError.missingApplicationSupportDirectory
        }
        rootURL = appSupport.appendingPathComponent("Recall", isDirectory: true)
        screenshotsURL = rootURL.appendingPathComponent("Screenshots", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("recall-state.json")
        try fileManager.createDirectory(at: screenshotsURL, withIntermediateDirectories: true)
    }

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        screenshotsURL = rootURL.appendingPathComponent("Screenshots", isDirectory: true)
        stateURL = rootURL.appendingPathComponent("recall-state.json")
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
    public var dailySummaries: [DailySummary]
    public var dailySummarySettings: DailySummarySettings
    public var privacy: PrivacySettings
    public var llmConfiguration: LLMConfiguration
    public var conversationSummary: String?
    public var conversationSummaryCoveredMessageCount: Int?

    public init(
        rules: [EventRule] = EventRule.defaults(),
        captures: [CaptureRecord] = [],
        messages: [ConversationMessage] = [],
        reminders: [ReminderCandidate] = [],
        dailySummaries: [DailySummary] = [],
        dailySummarySettings: DailySummarySettings = DailySummarySettings(),
        privacy: PrivacySettings = PrivacySettings(),
        llmConfiguration: LLMConfiguration = LLMConfiguration(),
        conversationSummary: String? = nil,
        conversationSummaryCoveredMessageCount: Int? = 0
    ) {
        self.rules = rules
        self.captures = captures
        self.messages = messages
        self.reminders = reminders
        self.dailySummaries = dailySummaries
        self.dailySummarySettings = dailySummarySettings
        self.privacy = privacy
        self.llmConfiguration = llmConfiguration
        self.conversationSummary = conversationSummary
        self.conversationSummaryCoveredMessageCount = conversationSummaryCoveredMessageCount
    }

    private enum CodingKeys: String, CodingKey {
        case rules, captures, messages, reminders, dailySummaries, dailySummarySettings
        case privacy, llmConfiguration, conversationSummary, conversationSummaryCoveredMessageCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([EventRule].self, forKey: .rules) ?? EventRule.defaults()
        captures = try container.decodeIfPresent([CaptureRecord].self, forKey: .captures) ?? []
        messages = try container.decodeIfPresent([ConversationMessage].self, forKey: .messages) ?? []
        reminders = try container.decodeIfPresent([ReminderCandidate].self, forKey: .reminders) ?? []
        dailySummaries = try container.decodeIfPresent([DailySummary].self, forKey: .dailySummaries) ?? []
        dailySummarySettings = try container.decodeIfPresent(DailySummarySettings.self, forKey: .dailySummarySettings) ?? DailySummarySettings()
        privacy = try container.decodeIfPresent(PrivacySettings.self, forKey: .privacy) ?? PrivacySettings()
        llmConfiguration = try container.decodeIfPresent(LLMConfiguration.self, forKey: .llmConfiguration) ?? LLMConfiguration()
        conversationSummary = try container.decodeIfPresent(String.self, forKey: .conversationSummary)
        conversationSummaryCoveredMessageCount = try container.decodeIfPresent(Int.self, forKey: .conversationSummaryCoveredMessageCount) ?? 0
    }
}

public actor FileMemoryStore {
    private let storage: RecallStorage
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: RecallState

    public init() throws {
        try self.init(storage: RecallStorage())
    }

    public init(storage: RecallStorage) throws {
        self.storage = storage
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
                try Self.write(restoredState, encoder: encoder, to: storage.stateURL)
            }
            state = restoredState
        } else {
            state = RecallState()
            try Self.write(state, encoder: encoder, to: storage.stateURL)
        }
    }

    public func snapshot() -> RecallState { state }

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

    public func deleteDailySummary(id: UUID) throws {
        state.dailySummaries.removeAll { $0.id == id }
        try persist()
    }

    public func clearDailySummaries() throws {
        state.dailySummaries = []
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

    public func updateReminder(_ reminder: ReminderCandidate) throws {
        guard let index = state.reminders.firstIndex(where: { $0.id == reminder.id }) else {
            state.reminders.insert(reminder, at: 0)
            try persist()
            return
        }
        state.reminders[index] = reminder
        try persist()
    }

    /// 批量忽略尚未被用户确认的候选提醒；已安排的系统通知不会受到影响。
    @discardableResult
    public func dismissAllProposedReminders() throws -> Int {
        var dismissedCount = 0
        state.reminders = state.reminders.map { reminder in
            guard reminder.status == .proposed else { return reminder }
            var updated = reminder
            updated.status = .dismissed
            dismissedCount += 1
            return updated
        }
        guard dismissedCount > 0 else { return 0 }
        try persist()
        return dismissedCount
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
    }

    private static func write(_ state: RecallState, encoder: JSONEncoder, to url: URL) throws {
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }
}
