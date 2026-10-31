import Foundation

public struct TimelineDayCount: Identifiable, Sendable {
    public let day: Date
    public let count: Int
    public var id: Date { day }
}

public struct TimelineQuery: Hashable, Sendable {
    public var day: Date
    public var searchText = ""
    public var searchAllDates = false
    public var source = ""
    public var collapseDuplicates = true
    public var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public init(day: Date = Calendar.current.startOfDay(for: .now)) { self.day = day }
}

public struct TimelineHour: Identifiable, Sendable {
    public let date: Date
    public let clusters: [TimelineRecordCluster]
    public var id: Date { date }
}

public struct TimelineQueryResult: Sendable {
    public let captures: [CaptureRecord]
    public let hours: [TimelineHour]
    public let clusterCount: Int
    public let sourceSummary: String
    public static let empty = Self(captures: [], hours: [], clusterCount: 0, sourceSummary: "")
}

/// An in-memory date index. Build once per source change, away from SwiftUI's body.
/// It holds the existing record values; no OCR parsing, disk reads or model calls.
public struct TimelineIndex: Sendable {
    public let days: [TimelineDayCount]
    public let sources: [String]
    public let maximumDayCount: Int
    private let records: [CaptureRecord]
    private let byDay: [Date: [CaptureRecord]]
    private let calendar: Calendar

    public init(captures: [CaptureRecord], calendar: Calendar = .current) throws {
        self.calendar = calendar
        try Task.checkCancellation()
        records = captures.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        var groups: [Date: [CaptureRecord]] = [:]
        var applications = Set<String>()
        for (offset, record) in records.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            groups[calendar.startOfDay(for: record.createdAt), default: []].append(record)
            if let app = record.sourceAppName { applications.insert(app) }
        }
        byDay = groups
        days = groups.keys.sorted(by: >).map { TimelineDayCount(day: $0, count: groups[$0]!.count) }
        maximumDayCount = days.map(\.count).max() ?? 1
        sources = applications.sorted()
    }

    public func result(for query: TimelineQuery) throws -> TimelineQueryResult {
        try Task.checkCancellation()
        let pool = query.searchAllDates && query.isSearching ? records : (byDay[calendar.startOfDay(for: query.day)] ?? [])
        let scoped = query.source.isEmpty ? pool : pool.filter { $0.sourceAppName == query.source }
        // Search preserves the established matching semantics; browsing preserves time order.
        let matches = query.isSearching
            ? MemorySearchEngine().search(MemorySearchQuery(text: query.searchText), in: scoped, limit: Int.max).map(\.capture)
            : scoped
        try Task.checkCancellation()
        let ordered = query.isSearching ? matches.sorted { $0.createdAt > $1.createdAt } : matches
        let clusters = TimelineRecordCluster.make(ordered, enabled: query.collapseDuplicates)
        let grouped = Dictionary(grouping: clusters) {
            calendar.dateInterval(of: .hour, for: $0.records[0].createdAt)?.start ?? $0.records[0].createdAt
        }
        let hours = grouped.keys.sorted(by: >).map { TimelineHour(date: $0, clusters: grouped[$0]!) }
        var counts: [String: Int] = [:]
        for record in matches { counts[record.sourceAppName ?? "其他", default: 0] += 1 }
        let entries: [(name: String, count: Int)] = counts.map { (name: $0.key, count: $0.value) }
        let ranked = entries.sorted { lhs, rhs in
            if lhs.count == rhs.count { return lhs.name < rhs.name }
            return lhs.count > rhs.count
        }
        let labels: [String] = ranked.prefix(4).map { entry in "\(entry.name) \(entry.count)" }
        let summary = labels.joined(separator: " · ")
        try Task.checkCancellation()
        return TimelineQueryResult(captures: matches, hours: hours, clusterCount: clusters.count, sourceSummary: summary)
    }
}
