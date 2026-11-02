import Foundation

public enum SourceProfile: String, Codable, Sendable {
    case slack, teams, email, document, meeting, generic
    public static func resolve(app: String?, bundle: String?, title: String?) -> Self {
        let name = [app, bundle, title].compactMap { $0 }.joined(separator: " ").lowercased()
        if name.contains("slack") { return .slack }
        if name.contains("teams") { return .teams }
        if name.contains("gmail") || name.contains("outlook") { return .email }
        if name.contains("notion") || name.contains("linear") { return .document }
        if name.contains("zoom") { return .meeting }; return .generic
    }
}
public struct SourceMessage: Codable, Hashable, Sendable {
    public var author: String?
    public var speaker: UnderstandingSpeaker
    public var text: String
    public var isReference: Bool
}
public enum SourceNormalizer {
    /// Only a user-confirmed, exact app/window/sender binding can promote a named sender.
    public static func messages(for record: CaptureRecord, bindings: [IdentityBinding]) -> [SourceMessage] {
        let source = record.correctedText ?? record.ocrText
        let matches = bindings.filter { $0.bundleIdentifier == record.sourceBundleIdentifier && $0.windowTitle == record.windowTitle }
        return source.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { line in
            let author = line.range(of: #"(?<=\[发言者·)[^\]]+(?=\])"#, options: .regularExpression).map { String(line[$0]) }
            var speaker: UnderstandingSpeaker = record.textOrigin == .userInput ? .user : .unknown
            if record.textOrigin != .importedText {
                if line.hasPrefix("[聊天·自己]") { speaker = .user }
                else if line.hasPrefix("[聊天·对方]") { speaker = .other }
                else if let author, matches.count == 1, matches[0].sender == author { speaker = .user }
            }
            let reference = record.textOrigin == .importedText || ["[内容·资料]", "[内容·附件]", "[内容·系统]", "[内容·片段]"].contains(where: line.contains)
            return SourceMessage(author: author, speaker: speaker, text: line, isReference: reference)
        }
    }
}
