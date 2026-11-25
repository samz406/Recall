import Foundation

/// 会话消息单独落盘。每条消息原本都会编码包含 OCR 的整份存档，
/// 存档越大越慢；消息与截图内容无关，放到独立的小文件里读写。
enum ConversationStore {
    static func read(from url: URL, decoder: JSONDecoder) -> [ConversationMessage]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([ConversationMessage].self, from: data)
    }

    static func write(_ messages: [ConversationMessage], to url: URL, encoder: JSONEncoder) throws {
        let data = try encoder.encode(messages)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
