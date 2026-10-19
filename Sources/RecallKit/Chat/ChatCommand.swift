import Foundation

/// Composer suggestions and local execution share the same command definitions.
public enum ChatCommand: String, CaseIterable, Identifiable, Sendable {
    case clear = "/clear"

    public var id: String { rawValue }
    public var title: String { "清空会话" }
    public var detail: String { "清空当前聊天记录和上下文" }
    public var symbol: String { "eraser" }

    public static func parse(_ input: String) -> ChatCommand? {
        ChatCommand(rawValue: input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func suggestions(for input: String) -> [ChatCommand] {
        guard !input.contains(where: \.isNewline) else { return [] }
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.hasPrefix("/"), !query.contains(where: \.isWhitespace) else { return [] }
        return allCases.filter { $0.rawValue.hasPrefix(query) }
    }

    public static func isCommandInput(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }
}
