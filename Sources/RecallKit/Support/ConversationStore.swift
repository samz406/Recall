import Foundation

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
        let data = try encoder.encode(messages)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// 会话存档：每个作用域（全局或某个主题）一套消息与上一轮来源，切换时互相隔离。
struct ConversationArchive: Codable, Sendable {
    struct Scope: Codable, Sendable {
        var messages: [ConversationMessage] = []
        /// 上一轮回答引用的来源，追问时优先作为候选。
        var lastCitedSourceIDs: [UUID] = []
        var updatedAt: Date = .now
    }
    var activeScope: String = ConversationArchive.globalScope
    var scopes: [String: Scope] = [:]

    static let globalScope = "global"
    static func topicScope(_ topicID: String) -> String { "topic:" + topicID }

    /// 兼容旧的裸消息数组。
    static func decode(_ data: Data, decoder: JSONDecoder) -> ConversationArchive? {
        if let archive = try? decoder.decode(ConversationArchive.self, from: data) { return archive }
        guard let legacy = try? decoder.decode([ConversationMessage].self, from: data) else { return nil }
        var archive = ConversationArchive()
        archive.scopes[Self.globalScope] = Scope(messages: legacy)
        return archive
    }
}
