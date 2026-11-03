import Foundation

/// Source browsing is an identity/metadata view, not a new summary of the OCR.
/// No ranked sentence parsing, image decoding or model calls happen here.
public struct ChatSourceRow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let app: String
    public let createdAt: Date
    init(_ record: CaptureRecord) {
        id = record.id; createdAt = record.createdAt
        app = Self.bounded(record.sourceAppName ?? "", limit: 64)
        let choices = [record.correctedText, record.understanding?.facts.first?.subject, record.summary, record.windowTitle]
        let savedTitle = choices.compactMap { $0 }.first { !$0.prefix(128).allSatisfy(\.isWhitespace) }
        let opening = String((record.correctedText ?? record.ocrText).prefix(384)).split(whereSeparator: \.isNewline).first.map(String.init)
        title = Self.bounded(savedTitle ?? opening ?? "", limit: 96)
    }
    private static func bounded(_ text: String, limit: Int) -> String {
        // Bound the input *before* trimming/counting, even for unusually large old summaries.
        let prefix = String(text.prefix(limit + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.count > limit ? String(prefix.prefix(limit)) + "…" : prefix
    }
}

public struct ChatSourcePage: Sendable {
    public static let pageSize = 20
    public let rows: [ChatSourceRow]
    public let total: Int
    public let page: Int
    public var pageCount: Int { max(1, (total + Self.pageSize - 1) / Self.pageSize) }
    public var firstPosition: Int { total == 0 ? 0 : page * Self.pageSize + 1 }
    public var lastPosition: Int { min(total, (page + 1) * Self.pageSize) }
}

public struct ChatSourceIndex: Sendable {
    private let records: [UUID: CaptureRecord]
    public init(captures: [CaptureRecord]) {
        records = Dictionary(captures.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }
    public func record(id: UUID) -> CaptureRecord? { records[id] }
    /// Keep citation order, remove duplicates and references whose sources are no longer permitted.
    public func availableIDs(_ citations: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return citations.filter { records[$0] != nil && seen.insert($0).inserted }
    }
    public func page(citations: [UUID], search: String = "", page: Int = 0) throws -> ChatSourcePage {
        try Task.checkCancellation()
        let ids = availableIDs(citations)
        let query = String(search.prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines)
        let selected: [UUID]
        if query.isEmpty { selected = ids }
        else {
            selected = try ids.filter { id in
                try Task.checkCancellation()
                guard let record = records[id] else { return false }
                let row = ChatSourceRow(record)
                return row.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || row.app.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        let lastPage = max(0, (selected.count - 1) / ChatSourcePage.pageSize)
        let current = min(max(0, page), lastPage), start = current * ChatSourcePage.pageSize
        let visible = selected.dropFirst(start).prefix(ChatSourcePage.pageSize)
        let rows = try visible.compactMap { id -> ChatSourceRow? in
            try Task.checkCancellation()
            return records[id].map(ChatSourceRow.init)
        }
        return ChatSourcePage(rows: rows, total: selected.count, page: current)
    }
}
