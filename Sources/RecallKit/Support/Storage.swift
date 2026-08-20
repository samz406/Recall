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
    public var privacy: PrivacySettings
    public var llmConfiguration: LLMConfiguration
    public var conversationSummary: String?
    public var conversationSummaryCoveredMessageCount: Int?

    public init(
        rules: [EventRule] = EventRule.defaults(),
        captures: [CaptureRecord] = [],
        messages: [ConversationMessage] = [],
        reminders: [ReminderCandidate] = [],
        privacy: PrivacySettings = PrivacySettings(),
        llmConfiguration: LLMConfiguration = LLMConfiguration(),
        conversationSummary: String? = nil,
        conversationSummaryCoveredMessageCount: Int? = 0
    ) {
        self.rules = rules
        self.captures = captures
        self.messages = messages
        self.reminders = reminders
        self.privacy = privacy
        self.llmConfiguration = llmConfiguration
        self.conversationSummary = conversationSummary
        self.conversationSummaryCoveredMessageCount = conversationSummaryCoveredMessageCount
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
