import Foundation

/// Derived from the original evidence so old captures gain the same presentation
/// improvements without rewriting OCR text, role attribution or stored state.
public struct CapturePresentation: Sendable {
    public let title: String
    public let summary: String
    public let tags: [String]

    public init(capture: CaptureRecord) {
        let evidence = capture.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = evidence.isEmpty ? (capture.summary ?? "") : evidence
        let ranked = LocalSummary.rankedSentences(from: text)
        if let first = ranked.first {
            title = LocalSummary.bounded(first.text, limit: 48)
            summary = LocalSummary.make(from: text) ?? ""
        } else {
            let window = LocalSummary.rankedSentences(from: capture.windowTitle ?? "").first?.text
            title = window.map { LocalSummary.bounded($0, limit: 48) }
                ?? "\(capture.sourceAppName ?? "当前窗口")的记录"
            summary = evidence.isEmpty
                ? "未识别出文本，可查看原始截图。"
                : "未提取到清晰正文，可查看完整识别文本和截图。"
        }
        tags = LocalSummary.tags(from: text)
    }
}

public enum LocalSummary {
    private static let cues = [
        "完成", "通过", "决定", "结论", "待办", "下一步", "阻塞", "失败", "目标", "需要",
        "修复", "方案", "评估", "设计", "implemented", "passed", "decision", "todo"
    ]
    private static let interfaceLabels: Set<String> = [
        "登录", "登陆", "注册", "设置", "搜索", "分享", "复制", "删除", "返回", "关闭",
        "新建聊天", "新对话", "新聊天", "聊天", "对方", "自己", "角色未知", "资料",
        "历史记录", "帮助", "菜单", "侧边栏", "附件", "发送", "更多", "升级", "重试",
        "new chat", "chatgpt", "claude", "gemini", "google chrome", "safari",
        "sign in", "log in", "login", "settings", "search", "share", "copy", "com", "www"
    ]

    public static func make(from text: String) -> String? {
        let selected = rankedSentences(from: text).prefix(2).sorted { $0.position < $1.position }
        guard !selected.isEmpty else { return nil }
        return bounded(selected.map(\.text).joined(separator: "；"), limit: 240)
    }

    public static func tags(from text: String) -> [String] {
        let stopWords = interfaceLabels.union([
            "今天", "当前", "这个", "那个", "可以", "需要", "已经", "然后", "页面", "用户",
            "window", "chrome", "chat", "http", "https"
        ])
        let tokens = rankedSentences(from: text).map(\.text).joined(separator: " ")
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
            .filter { (2...16).contains($0.count) && !stopWords.contains($0.lowercased()) }
            .filter { $0.contains(where: \.isLetter) }
        let counts = Dictionary(grouping: tokens, by: { $0.lowercased() }).mapValues { $0.count }
        var seen: Set<String> = []
        return tokens.enumerated()
            .filter { seen.insert($0.element.lowercased()).inserted }
            .sorted { lhs, rhs in
                let left = counts[lhs.element.lowercased(), default: 0]
                let right = counts[rhs.element.lowercased(), default: 0]
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .prefix(8).map(\.element)
    }

    static func rankedSentences(from text: String) -> [(text: String, position: Int)] {
        var seen: Set<String> = []
        // Strip chrome and role markers for presentation only. Full evidence is
        // retained verbatim, including role labels used by downstream reasoning.
        let cleaned = text.components(separatedBy: .newlines).map(cleanLine).joined(separator: "\n")
        return cleaned.components(separatedBy: CharacterSet(charactersIn: "。！？!?；;\n"))
            .enumerated()
            .compactMap { position, raw -> (text: String, position: Int)? in
                let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                let key = sentence.lowercased()
                guard sentence.count >= 4, sentence.contains(where: \.isLetter),
                      !interfaceLabels.contains(key), seen.insert(key).inserted else { return nil }
                return (sentence, position)
            }
            .sorted { lhs, rhs in
                let left = sentenceScore(lhs.text, position: lhs.position)
                let right = sentenceScore(rhs.text, position: rhs.position)
                return left == right ? lhs.position < rhs.position : left > right
            }
    }

    private static func cleanLine(_ line: String) -> String {
        var result = line.replacingOccurrences(of: #"\[聊天\s*[·・]\s*(?:对方|自己|角色未知)\]"#, with: "", options: .regularExpression)
        // Remove URL tokens rather than discard a useful sentence containing a link.
        result = result.replacingOccurrences(
            of: #"(?i)(?:https?://|www\.)[^\s，。；！？<>\[\]]+|\b(?:[a-z0-9-]+\.)+(?:com|org|net|ai|io|cn|dev|app|site)(?:/[^\s，。；！？<>\[\]]*)?\b"#,
            with: "", options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let key = trimmed.lowercased()
        if interfaceLabels.contains(key) { return "" }
        // OCR often bundles a browser title with its address or an icon character.
        if trimmed.range(of: #"(?i)^[\W\d]*(?:[a-z]\s+)?(?:chatgpt|claude|gemini|new chat|google chrome|safari)[\W\d]*$"#, options: .regularExpression) != nil {
            return ""
        }
        return trimmed
    }

    static func bounded(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private static func sentenceScore(_ sentence: String, position: Int) -> Double {
        let normalized = sentence.lowercased()
        var score = max(0, 0.2 - Double(position) * 0.01)
        score += Double(cues.filter { normalized.contains($0) }.count) * 0.45
        if (12...180).contains(sentence.count) { score += 0.18 }
        if sentence.count > 300 { score -= 0.25 }
        return score
    }
}
