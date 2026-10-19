import Foundation

/// 保留每条原始消息的说话人；句号/分号之后仍属于同一人，下一行无标记则恢复未知。
/// 不通过来源应用名猜测说话人，也不把“手动截图”当成用户输入。
struct RecordedText: Sendable {
    enum Speaker: Sendable { case user, other, unknown, unattributed }

    struct Segment: Sendable {
        let text: String
        let speaker: Speaker
        let ordinal: Int
    }

    static func segments(in record: CaptureRecord) -> [Segment] {
        var result: [Segment] = []
        for rawLine in record.ocrText.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker: Speaker
            if line.hasPrefix("[聊天·自己]") { speaker = .user }
            else if line.hasPrefix("[聊天·对方]") { speaker = .other }
            else if line.hasPrefix("[聊天·角色未知]") { speaker = .unknown }
            else { speaker = record.textOrigin == .userInput ? .user : .unattributed }
            line = line.replacingOccurrences(of: #"^\[聊天·(?:自己|对方|角色未知)\]\s*"#, with: "", options: .regularExpression)
            // Saved/forwarded material and file cards remain searchable evidence,
            // but cannot create personal facts, work completion or user reminders.
            if line.hasPrefix("[内容·资料]") || line.hasPrefix("[内容·附件]") { continue }
            var buffer = ""
            var closing: [Character] = []
            let pairs: [Character: Character] = ["（": "）", "(": ")", "【": "】", "[": "]", "“": "”", "‘": "’", "「": "」", "《": "》"]
            for character in line {
                buffer.append(character)
                if let end = pairs[character] { closing.append(end) }
                else if closing.last == character { closing.removeLast() }
                if closing.isEmpty && "。！？!?；;".contains(character) {
                    append(buffer, speaker: speaker, to: &result)
                    buffer = ""
                }
            }
            append(buffer, speaker: speaker, to: &result)
        }
        return result
    }

    private static func append(_ text: String, speaker: Speaker, to result: inout [Segment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(Segment(text: trimmed, speaker: speaker, ordinal: result.count)) }
    }
}
