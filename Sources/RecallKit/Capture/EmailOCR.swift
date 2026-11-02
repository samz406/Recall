import Foundation

/// Conservative plain-header extraction for mail windows. Unknown layouts keep their full text.
/// Mail is reference material: an email author's 'I' is never the local user's identity.
public enum EmailOCRFormatter {
    public static func format(_ lines: [PositionedTextLine]) -> String {
        let ordered = lines.sorted { $0.boundingBox.midY == $1.boundingBox.midY ? $0.boundingBox.minX < $1.boundingBox.minX : $0.boundingBox.midY > $1.boundingBox.midY }
        let rows = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let headers = ["from:", "to:", "subject:", "date:", "发件人：", "收件人：", "主题：", "日期："]
        let found = rows.enumerated().filter { row in headers.contains { row.element.lowercased().hasPrefix($0) } }
        let distinct = Set(found.compactMap { row in headers.first { row.element.lowercased().hasPrefix($0) } })
        let body = distinct.count >= 2 ? Array(rows.dropFirst(found.first?.offset ?? 0)) : rows
        return body.map { "[聊天·角色未知] [内容·资料] " + $0 }.joined(separator: "\n")
    }
}
