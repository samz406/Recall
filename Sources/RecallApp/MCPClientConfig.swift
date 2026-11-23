import Foundation
import RecallKit

/// Connection snippets for common MCP clients. The token is the authorization; the client name is a label
/// that must match what the client reports, so it stays editable.
enum MCPClientConfig {
    enum Client: String, CaseIterable, Identifiable {
        case claudeDesktop, claudeCode, cursor, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claudeDesktop: "Claude Desktop"
            case .claudeCode: "Claude Code"
            case .cursor: "Cursor"
            case .other: RecallLocalization.both("其他客户端", "Other client")
            }
        }
        /// A starting value for the client name. Clients can change what they report; verify on first connect.
        var suggestedName: String {
            switch self {
            case .claudeDesktop: "claude-ai"
            case .claudeCode: "claude-code"
            case .cursor: "cursor-vscode"
            case .other: ""
            }
        }
        var whereToPaste: String {
            switch self {
            case .claudeDesktop: RecallLocalization.both("粘贴到 ~/Library/Application Support/Claude/claude_desktop_config.json 的 mcpServers 中。", "Paste into mcpServers in ~/Library/Application Support/Claude/claude_desktop_config.json.")
            case .claudeCode: RecallLocalization.both("在终端运行复制的命令。", "Run the copied command in a terminal.")
            case .cursor: RecallLocalization.both("粘贴到 ~/.cursor/mcp.json 的 mcpServers 中。", "Paste into mcpServers in ~/.cursor/mcp.json.")
            case .other: RecallLocalization.both("按客户端说明填写 command、args 和 env。", "Fill command, args and env as your client expects.")
            }
        }
    }

    /// The CLI is a product of the same SwiftPM build, so it sits next to the app's executable build directory.
    static func bundledCLI() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("recall-cli"))
            // run-app.sh copies only RecallApp into .build/Recall.app; the CLI stays in .build/<config>.
            let build = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            candidates += ["debug", "release"].map { build.appendingPathComponent($0).appendingPathComponent("recall-cli") }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static func json(for client: Client, executable: URL, dataDir: URL, token: String) -> String? {
        let args = ["mcp", "--data-dir", dataDir.path]
        if client == .claudeCode {
            let quoted = ([executable.path] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            return "claude mcp add recall --env RECALL_MCP_TOKEN=\(token) -- \(quoted)"
        }
        let server: [String: Any] = ["command": executable.path, "args": args, "env": ["RECALL_MCP_TOKEN": token]]
        let config: [String: Any] = ["mcpServers": ["recall": server]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
