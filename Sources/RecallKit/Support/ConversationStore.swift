import Foundation

public struct ConversationSessionSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var topicID: String?
    public var messageCount: Int
    public var updatedAt: Date
    public var isActive: Bool

    public init(id: UUID, title: String, topicID: String?, messageCount: Int, updatedAt: Date, isActive: Bool) {
        self.id = id
        self.title = title
        self.topicID = topicID
        self.messageCount = messageCount
        self.updatedAt = updatedAt
        self.isActive = isActive
    }
}

/// 会话消息单独落盘。每条消息原本都会编码包含 OCR 的整份存档，
/// 存档越大越慢；消息与截图内容无关，放到独立的小文件里读写。
enum ConversationStore {
    static func read(from url: URL, decoder: JSONDecoder) -> [ConversationMessage]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([ConversationMessage].self, from: data)
    }

    static func readArchive(from url: URL, decoder: JSONDecoder) -> ConversationArchive? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ConversationArchive.decode(data, decoder: decoder)
    }

    static func write(_ messages: [ConversationMessage], to url: URL, encoder: JSONEncoder) throws {
        var archive = ConversationArchive()
        archive.seedLegacyGlobal(messages: messages, summary: nil, coveredCount: 0)
        try writeArchive(archive, to: url, encoder: encoder)
    }

    static func writeArchive(_ archive: ConversationArchive, to url: URL, encoder: JSONEncoder) throws {
        let data = try encoder.encode(archive)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// 会话存档：支持多会话线程（全局与各主题独立归属），兼容旧版按作用域单会话及裸消息数组。
struct ConversationArchive: Codable, Sendable {
    struct Scope: Codable, Sendable {
        var messages: [ConversationMessage] = []
        /// 上一轮回答引用的来源，追问时优先作为候选。
        var lastCitedSourceIDs: [UUID] = []
        var updatedAt: Date = .now
    }

    struct Thread: Codable, Identifiable, Sendable {
        var id: UUID = UUID()
        var title: String = ""
        var topicID: String? = nil
        var messages: [ConversationMessage] = []
        var lastCitedSourceIDs: [UUID] = []
        var conversationSummary: String? = nil
        var coveredMessageCount: Int = 0
        var createdAt: Date = .now
        var updatedAt: Date = .now

        var scopeKey: String {
            topicID.map(ConversationArchive.topicScope) ?? ConversationArchive.globalScope
        }

        var nonSystemMessages: [ConversationMessage] {
            messages.filter { $0.role != .system }
        }

        static func deriveTitle(from messages: [ConversationMessage]) -> String {
            guard let first = messages.first(where: { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") }) else {
                return ""
            }
            let collapsed = first.content
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !collapsed.isEmpty else { return "" }
            return collapsed.count > 36 ? String(collapsed.prefix(36)) + "…" : collapsed
        }
    }

    var activeScope: String = ConversationArchive.globalScope
    var scopes: [String: Scope] = [:]
    var threads: [Thread] = []
    var activeThreadByScope: [String: UUID] = [:]

    static let globalScope = "global"
    static func topicScope(_ topicID: String) -> String { "topic:" + topicID }
    static func topicID(fromScope scope: String) -> String? {
        guard scope.hasPrefix("topic:") else { return nil }
        let raw = String(scope.dropFirst("topic:".count))
        return raw.isEmpty ? nil : raw
    }

    mutating func seedLegacyGlobal(messages: [ConversationMessage], summary: String?, coveredCount: Int) {
        let thread = Self.sanitize(Thread(
            title: Thread.deriveTitle(from: messages),
            topicID: nil,
            messages: messages,
            conversationSummary: summary,
            coveredMessageCount: coveredCount
        ))
        activeScope = Self.globalScope
        threads = [thread]
        activeThreadByScope = [Self.globalScope: thread.id]
        syncLegacyScopes()
    }

    @discardableResult
    mutating func ensureActiveThread(for scope: String? = nil) -> Thread {
        let targetScope = scope ?? activeScope
        if let activeID = activeThreadByScope[targetScope],
           let existing = threads.first(where: { $0.id == activeID && $0.scopeKey == targetScope }) {
            return existing
        }
        if let newest = threads.filter({ $0.scopeKey == targetScope }).max(by: { $0.updatedAt < $1.updatedAt }) {
            activeThreadByScope[targetScope] = newest.id
            return newest
        }
        let created = Thread(topicID: Self.topicID(fromScope: targetScope))
        threads.append(created)
        activeThreadByScope[targetScope] = created.id
        syncLegacyScopes()
        return created
    }

    var currentThreadID: UUID? {
        activeThreadByScope[activeScope]
    }

    mutating func updateCurrentThread(
        messages: [ConversationMessage],
        summary: String?,
        coveredCount: Int,
        touchUpdatedAt: Bool = true
    ) {
        let current = ensureActiveThread(for: activeScope)
        guard let index = threads.firstIndex(where: { $0.id == current.id }) else { return }
        threads[index].messages = messages
        threads[index].conversationSummary = summary
        threads[index].coveredMessageCount = max(0, coveredCount)
        let derived = Thread.deriveTitle(from: messages)
        if !derived.isEmpty {
            threads[index].title = derived
        } else if messages.allSatisfy({ $0.role == .system }) {
            threads[index].title = ""
        }
        if touchUpdatedAt {
            threads[index].updatedAt = .now
        }
        syncLegacyScopes()
    }

    mutating func setCurrentCitations(_ ids: [UUID], inScope scope: String) {
        guard scope == activeScope else { return }
        let current = ensureActiveThread(for: scope)
        guard let index = threads.firstIndex(where: { $0.id == current.id }) else { return }
        threads[index].lastCitedSourceIDs = ids
        syncLegacyScopes()
    }

    mutating func rewriteTopicID(from oldTopicID: String, to newTopicID: String) {
        guard oldTopicID != newTopicID else { return }
        let oldScope = Self.topicScope(oldTopicID)
        let newScope = Self.topicScope(newTopicID)
        var changed = false
        for index in threads.indices where threads[index].topicID == oldTopicID {
            threads[index].topicID = newTopicID
            changed = true
        }
        if let activeID = activeThreadByScope.removeValue(forKey: oldScope) {
            if activeThreadByScope[newScope] == nil {
                activeThreadByScope[newScope] = activeID
            }
            changed = true
        }
        if activeScope == oldScope {
            activeScope = newScope
            changed = true
        }
        if changed {
            scopes.removeValue(forKey: oldScope)
            syncLegacyScopes()
        }
    }

    func currentCitations() -> [UUID] {
        guard let id = activeThreadByScope[activeScope],
              let thread = threads.first(where: { $0.id == id }) else {
            return scopes[activeScope]?.lastCitedSourceIDs ?? []
        }
        return thread.lastCitedSourceIDs
    }

    @discardableResult
    mutating func startNewThread(topicID: String?) -> Thread {
        let scope = topicID.map(Self.topicScope) ?? Self.globalScope
        activeScope = scope
        let current = ensureActiveThread(for: scope)
        if current.nonSystemMessages.isEmpty, let index = threads.firstIndex(where: { $0.id == current.id }) {
            threads[index].messages = []
            threads[index].lastCitedSourceIDs = []
            threads[index].conversationSummary = nil
            threads[index].coveredMessageCount = 0
            threads[index].title = ""
            threads[index].updatedAt = .now
            syncLegacyScopes()
            return threads[index]
        }
        let fresh = Thread(topicID: topicID)
        threads.append(fresh)
        activeThreadByScope[scope] = fresh.id
        syncLegacyScopes()
        return fresh
    }

    mutating func selectThread(id: UUID) -> Thread? {
        guard let thread = threads.first(where: { $0.id == id }) else { return nil }
        let scope = thread.scopeKey
        activeScope = scope
        activeThreadByScope[scope] = thread.id
        syncLegacyScopes()
        return thread
    }

    mutating func deleteThread(id: UUID) -> Thread {
        let removedScope = threads.first(where: { $0.id == id })?.scopeKey
        threads.removeAll { $0.id == id }
        if let removedScope, activeThreadByScope[removedScope] == id {
            activeThreadByScope.removeValue(forKey: removedScope)
        }
        let active = ensureActiveThread(for: activeScope)
        syncLegacyScopes()
        return active
    }

    @discardableResult
    mutating func deleteThreads(forTopicID topicID: String) -> Bool {
        let scope = Self.topicScope(topicID)
        let beforeCount = threads.count
        let hadLegacy = scopes.removeValue(forKey: scope) != nil
        threads.removeAll { $0.scopeKey == scope }
        activeThreadByScope.removeValue(forKey: scope)
        guard threads.count != beforeCount || hadLegacy else { return false }
        if activeScope == scope {
            activeScope = Self.globalScope
            _ = ensureActiveThread(for: Self.globalScope)
        }
        syncLegacyScopes()
        return true
    }

    func summaries() -> [ConversationSessionSummary] {
        let activeID = activeThreadByScope[activeScope]
        return threads
            .filter { !$0.nonSystemMessages.isEmpty }
            .sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.createdAt > rhs.createdAt : lhs.updatedAt > rhs.updatedAt
            }
            .map { thread in
                let rawTitle = thread.title.isEmpty ? Thread.deriveTitle(from: thread.messages) : thread.title
                let fallback = RecallLocalization.both("未命名对话", "Untitled chat")
                return ConversationSessionSummary(
                    id: thread.id,
                    title: rawTitle.isEmpty ? fallback : rawTitle,
                    topicID: thread.topicID,
                    messageCount: thread.nonSystemMessages.count,
                    updatedAt: thread.updatedAt,
                    isActive: thread.id == activeID
                )
            }
    }

    mutating func syncLegacyScopes() {
        var mapped: [String: Scope] = [:]
        let scopeKeys = Set(threads.map(\.scopeKey)).union([activeScope])
        for key in scopeKeys {
            let chosen: Thread?
            if let id = activeThreadByScope[key], let match = threads.first(where: { $0.id == id && $0.scopeKey == key }) {
                chosen = match
            } else {
                chosen = threads.filter { $0.scopeKey == key }.max { $0.updatedAt < $1.updatedAt }
            }
            if let chosen {
                mapped[key] = Scope(messages: chosen.messages, lastCitedSourceIDs: chosen.lastCitedSourceIDs, updatedAt: chosen.updatedAt)
            }
        }
        scopes = mapped
    }

    static func sanitize(_ thread: Thread) -> Thread {
        var restored = thread
        for i in restored.messages.indices where !restored.messages[i].citations.isEmpty {
            let message = restored.messages[i]
            if message.role == .assistant && AnswerGrounding.isNoEvidenceReply(message.content) {
                restored.messages[i].citations = []
                restored.messages[i].sourceVersions = nil
            }
        }
        if let last = restored.messages.last(where: { $0.role == .assistant }), AnswerGrounding.isNoEvidenceReply(last.content) {
            restored.lastCitedSourceIDs = []
        }
        if restored.title.isEmpty {
            restored.title = Thread.deriveTitle(from: restored.messages)
        }
        return restored
    }

    /// 兼容旧的按作用域单会话存档及裸消息数组。
    static func decode(_ data: Data, decoder: JSONDecoder) -> ConversationArchive? {
        var archive: ConversationArchive
        if let decoded = try? decoder.decode(Self.self, from: data) {
            archive = decoded
            if archive.threads.isEmpty, !archive.scopes.isEmpty {
                for (scopeKey, scope) in archive.scopes.sorted(by: { $0.key < $1.key }) {
                    let thread = sanitize(Thread(
                        title: Thread.deriveTitle(from: scope.messages),
                        topicID: topicID(fromScope: scopeKey),
                        messages: scope.messages,
                        lastCitedSourceIDs: scope.lastCitedSourceIDs,
                        createdAt: scope.updatedAt,
                        updatedAt: scope.updatedAt
                    ))
                    archive.threads.append(thread)
                    archive.activeThreadByScope[scopeKey] = thread.id
                }
            } else {
                archive.threads = archive.threads.map(sanitize)
            }
        } else if let legacy = try? decoder.decode([ConversationMessage].self, from: data) {
            archive = ConversationArchive()
            archive.seedLegacyGlobal(messages: legacy, summary: nil, coveredCount: 0)
        } else {
            return nil
        }
        _ = archive.ensureActiveThread(for: archive.activeScope)
        archive.syncLegacyScopes()
        return archive
    }
}
