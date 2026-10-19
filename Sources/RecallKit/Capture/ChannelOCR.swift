import CoreGraphics
import Foundation

/// Channel-style chats preserve visible authors, not inferred account ownership.
/// All crop bounds are verified by the image layout detector before text is filtered.
public enum ChannelOCRFormatter {
    private struct Row {
        var text: String
        var bounds: CGRect
    }
    public static func format(_ lines: [PositionedTextLine], layout: ConversationOCRLayout?) -> String {
        guard let layout else {
            return lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.map { "[聊天·角色未知] " + $0 }.joined(separator: "\n")
        }
        let pane = layout.contentBounds
        let visible = lines.filter { coverage($0.boundingBox, pane) >= 0.7 }
        // Avatar initials sit left of the message text. Infer the text column from
        // actual author/time headers so compact layouts don't lose their narrow margin.
        var authorColumns = visible.compactMap { line -> CGFloat? in
            senderHeader(line.text) == nil ? nil : line.boundingBox.minX
        }
        for time in visible where timestampOnly(time.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let preceding = visible.filter { candidate in
                candidate.boundingBox.maxX <= time.boundingBox.minX
                    && abs(candidate.boundingBox.midY - time.boundingBox.midY) < min(candidate.boundingBox.height, time.boundingBox.height) * 0.6
            }.max { $0.boundingBox.maxX < $1.boundingBox.maxX }
            if let preceding { authorColumns.append(preceding.boundingBox.minX) }
        }
        let authorColumn = authorColumns.min()
        let body = rows(visible.filter { line in
            guard let authorColumn else { return true }
            return line.boundingBox.maxX >= authorColumn - line.boundingBox.height * 0.4
        })
        let header = rows(lines.filter { $0.boundingBox.minX >= pane.minX && $0.boundingBox.minY >= pane.maxY })
        let channel = header.compactMap { row -> String? in
            guard let range = row.text.range(of: #"#[\s]*[\p{L}\p{N}_][\p{L}\p{N}_.\-]*"#, options: .regularExpression) else { return nil }
            return String(row.text[range]).replacingOccurrences(of: " ", with: "")
        }.last
        var result: [String] = [], pending: [String] = []
        var author: String?, timestamp: String?, date: String?
        func metadata() -> String {
            [channel.map { "[频道·\(safe($0))]" }, author.map { "[发言者·\(safe($0))]" },
             [date, timestamp].compactMap { $0 }.joined(separator: " ").nonempty.map { "[时间·\(safe($0))]" }]
                .compactMap { $0 }.joined(separator: " ")
        }
        func flush() {
            guard !pending.isEmpty else { return }
            let text = pending.joined(separator: " ")
            let kind = ConversationContentClassifier.classify(text)
            let type: String = switch kind { case .message: author == nil ? "[内容·片段] " : ""; case .reference: "[内容·资料] "; case .attachment: "[内容·附件] " }
            let meta = metadata()
            result.append("[聊天·角色未知] " + (meta.isEmpty ? "" : meta + " ") + type + text)
            pending.removeAll(keepingCapacity: true)
        }
        for row in body {
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.contains(where: \.isLetter) || text.contains(where: \.isNumber) else { continue }
            if isDate(text) {
                flush(); author = nil; timestamp = nil; date = text
            } else if isSystem(text) {
                flush(); author = nil; timestamp = nil
                let meta = metadata()
                result.append("[聊天·角色未知] " + (meta.isEmpty ? "" : meta + " ") + "[内容·系统] " + text)
            } else if let sender = senderHeader(text) {
                flush(); author = sender.name; timestamp = sender.time
            } else if isThreadControl(text) {
                // The count is interface state. Replies are unavailable until expanded.
                continue
            } else if timestampOnly(text), author != nil {
                timestamp = text
            } else {
                pending.append(text)
            }
        }
        flush()
        return result.joined(separator: "\n")
    }

    private static func senderHeader(_ text: String) -> (name: String, time: String)? {
        let pattern = #"^(.{1,48}?)\s+((?:(?:上午|下午|早上|晚上|AM|PM)\s*)?\d{1,2}[:：]\d{2}(?:\s*(?:AM|PM))?)(?:\s*(?:\(edited\)|已编辑|\(已编辑\)))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text), let timeRange = Range(match.range(at: 2), in: text) else { return nil }
        let name = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        // An ordinary sentence ending in a time is not an author header.
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: "，。！？；:：!?;")) == nil,
              !["我", "我们", "请", "明天", "今天", "会议定在", "时间是", "提醒我"].contains(where: name.hasPrefix) else { return nil }
        return (name, String(text[timeRange]))
    }
    private static func timestampOnly(_ text: String) -> Bool {
        text.range(of: #"^(?:(?:上午|下午|早上|晚上|AM|PM)\s*)?\d{1,2}[:：]\d{2}(?:\s*(?:AM|PM))?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func isDate(_ text: String) -> Bool {
        text.range(of: #"^(?:今天|昨天|前天|Today|Yesterday|(?:\d{4}年\s*)?\d{1,2}\s*月\s*\d{1,2}\s*日(?:\s*(?:星期|周)[一二三四五六日天])?|(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)[,\s]+.*|(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func isSystem(_ text: String) -> Bool {
        text.range(of: #"(?i)(?:^.{1,80}(?:已加入|加入了)\s*#|^.{1,100}renamed the channel from\s|^.{1,100}已由.{1,80}添加到\s*#|^.{1,80}has joined\s*#|^.{1,80}was added to\s*#)"#, options: .regularExpression) != nil
    }
    private static func isThreadControl(_ text: String) -> Bool {
        text.range(of: #"(?i)^(?:[\p{L}\p{N}_.\-]{1,16}\s+)?\d+\s*(?:条回复|个回复|repl(?:y|ies))(?:\s+(?:Last reply|最后回复|上次回复).*)?$"#, options: .regularExpression) != nil
    }
    private static func safe(_ text: String) -> String { text.replacingOccurrences(of: "[", with: "（").replacingOccurrences(of: "]", with: "）") }
    private static func coverage(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard a.width > 0 && a.height > 0 else { return 0 }
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height / (a.width * a.height)
    }
    private static func rows(_ lines: [PositionedTextLine]) -> [Row] {
        var grouped: [[PositionedTextLine]] = []
        for line in lines.sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
            if let last = grouped.last, let anchor = last.first,
               abs(anchor.boundingBox.midY - line.boundingBox.midY) <= min(anchor.boundingBox.height, line.boundingBox.height) * 0.45 {
                grouped[grouped.count - 1].append(line)
            } else { grouped.append([line]) }
        }
        return grouped.map { group in
            let ordered = group.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            return Row(text: ordered.map(\.text).joined(separator: " "), bounds: ordered.dropFirst().reduce(ordered[0].boundingBox) { $0.union($1.boundingBox) })
        }
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}
