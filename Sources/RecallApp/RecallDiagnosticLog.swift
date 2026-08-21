import Foundation
import RecallKit

enum RecallDiagnosticLevel: String, Codable, CaseIterable {
    case info
    case warning
    case error

    var title: String {
        switch self {
        case .info: "信息"
        case .warning: "警告"
        case .error: "错误"
        }
    }
}

struct RecallDiagnosticEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let level: RecallDiagnosticLevel
    let source: String
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        level: RecallDiagnosticLevel,
        source: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.level = level
        self.source = source
        self.message = message
        self.metadata = metadata
    }
}

/// Stores a short local diagnostic trail for the app itself.
/// Deliberately excludes API keys, user-entered text, OCR output, screenshots and model responses.
@MainActor
final class RecallDiagnosticLogStore {
    private static let maximumEntryCount = 200

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private(set) var entries: [RecallDiagnosticEntry]

    init(storage: RecallStorage, fileManager: FileManager = .default) {
        fileURL = storage.rootURL.appendingPathComponent("diagnostics.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: fileURL),
              let restored = try? decoder.decode([RecallDiagnosticEntry].self, from: data) else {
            entries = []
            return
        }
        entries = Array(restored.prefix(Self.maximumEntryCount))
    }

    func record(
        _ level: RecallDiagnosticLevel,
        source: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let safeMetadata = metadata.filter { key, _ in
            let normalized = key.lowercased()
            return !normalized.contains("key") && !normalized.contains("text") && !normalized.contains("content") && !normalized.contains("prompt")
        }
        let entry = RecallDiagnosticEntry(level: level, source: source, message: message, metadata: safeMetadata)
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntryCount {
            entries.removeLast(entries.count - Self.maximumEntryCount)
        }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

func recallSafeErrorCode(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain)#\(nsError.code)"
}
