import Foundation

public enum EvidenceAccess {
    public static func records(_ state: RecallState) -> [CaptureRecord] {
        let invalid = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        return state.captures.filter {
            !invalid.contains($0.id) && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "")
                && $0.memoryDirective == nil && $0.isMemoryEvidenceArchive != true && $0.eventTemplate != .dailyReview
        }
    }
}
public enum EvidenceLinkRouter {
    public static func captureID(_ url: URL) -> UUID? {
        guard url.scheme == "recall", url.host == "capture", url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
    public static func link(_ id: UUID) -> String { "recall://capture/" + id.uuidString }
}
public struct EvidenceExport: Sendable {
    public let markdown: String
    public let sourceVersions: [UUID: String]
}
public enum EvidenceExportBuilder {
    public static func answer(_ message: ConversationMessage, state: RecallState, now: Date = .now) throws -> EvidenceExport {
        guard message.role == .assistant, !message.citations.isEmpty else { throw WorkflowError.invalid }
        let records = Dictionary(uniqueKeysWithValues: EvidenceAccess.records(state).map { ($0.id, $0) })
        guard message.citations.allSatisfy({ records[$0] != nil }) else { throw WorkflowError.changed }
        let saved = state.messages.first { $0.id == message.id }
        guard saved?.content == message.content, saved?.citations == message.citations else { throw WorkflowError.changed }
        if let versions = message.sourceVersions {
            guard message.citations.allSatisfy({ id in versions[id.uuidString] == records[id].map { CaptureUnderstandingEngine.sourceVersion($0, in: state) } }) else { throw WorkflowError.changed }
        } else {
            // Older answers have no immutable evidence version: do not certify their citations after edits.
            guard message.citations.allSatisfy({ records[$0]?.correctedText == nil }) else { throw WorkflowError.changed }
        }
        var versions: [UUID: String] = [:]
        var sections = ["# Recall", PrivacyEngine().redact(message.content), "## " + RecallLocalization.text("回答依据"),
            RecallLocalization.text("以下来源支持整段回答，不表示每句话都有单独核验。")]
        for id in message.citations {
            guard let record = records[id] else { throw WorkflowError.changed }
            versions[id] = CaptureUnderstandingEngine.sourceVersion(record, in: state)
            let label = escape(record.sourceAppName ?? "Record")
            let date = ISO8601DateFormatter().string(from: record.createdAt)
            let quote = PrivacyEngine().redact(record.correctedText ?? record.ocrText).prefix(360)
            sections.append("- **\(label)** · \(date)\n\n" + quote.components(separatedBy: .newlines).map { "> " + escape($0) }.joined(separator: "\n"))
        }
        sections.append("---\n" + RecallLocalization.text("创建时间") + ": " + ISO8601DateFormatter().string(from: now))
        return EvidenceExport(markdown: sections.joined(separator: "\n\n"), sourceVersions: versions)
    }
    public static func validate(_ export: EvidenceExport, state: RecallState) -> Bool {
        let records = Dictionary(uniqueKeysWithValues: EvidenceAccess.records(state).map { ($0.id, $0) })
        return export.sourceVersions.allSatisfy { id, version in records[id].map { CaptureUnderstandingEngine.sourceVersion($0, in: state) == version } == true }
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "`", with: "\\`")
    }
}
