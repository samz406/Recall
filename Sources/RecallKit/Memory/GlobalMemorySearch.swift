import Foundation
import CryptoKit

public struct GlobalMemorySearchQuery: Hashable, Sendable {
    public var text: String
    public var start: Date?
    public var end: Date?
    public var app: String?
    public var topicSources: Set<UUID>?
    public init(text: String = "", start: Date? = nil, end: Date? = nil, app: String? = nil, topicSources: Set<UUID>? = nil) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.start = start; self.end = end; self.app = app?.isEmpty == false ? app : nil; self.topicSources = topicSources
    }
    public var hasCriteria: Bool { !text.isEmpty || start != nil || end != nil || app != nil || topicSources != nil }
}

/// Metadata and original text references only. No OCR summarization or tokenization on opening search.
public struct GlobalMemorySearch: Sendable {
    private enum VersionKind: String, Sendable { case daily, memory, weekly, legacy }
    private struct Signature: Sendable { var id: UUID; var expected: String; var kind: VersionKind }
    private struct Document: Sendable {
        var hit: MemorySearchHit
        var text: String
        var signatures: [Signature] = []
        var validUntil: Date? = nil
    }
    /// Hash only matching derived documents' sources; share these checks across queries.
    private final class Versions: @unchecked Sendable {
        private let state: RecallState
        private let sources: [UUID: CaptureRecord]
        private let lock = NSLock()
        private var values: [String: String] = [:]
        init(_ state: RecallState, sources: [CaptureRecord]) {
            self.state = state
            self.sources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        func matches(_ signature: Signature) -> Bool {
            let key = signature.kind.rawValue + ":" + signature.id.uuidString
            lock.lock(); let cached = values[key]; lock.unlock()
            if let cached { return cached == signature.expected }
            guard let source = sources[signature.id] else { return false }
            let value: String
            switch signature.kind {
            case .daily:
                value = CaptureUnderstandingEngine.sourceVersion(source, in: state)
            case .memory:
                guard let adjusted = state.analysisCaptures(for: [source.id])[source.id] else { return false }
                value = MemoryKnowledgeEngine.version(of: adjusted, corrections: state.matterCorrections)
            case .weekly:
                value = "memory2:" + MemoryKnowledgeEngine.version(of: SummaryFeedbackLearning.adjusted(source, in: state), corrections: state.matterCorrections)
            case .legacy:
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                let data = (try? encoder.encode(source)) ?? Data()
                let edits = (try? encoder.encode(state.matterCorrections.filter { $0.evidenceIDs.contains(source.id) })) ?? Data()
                value = SHA256.hash(data: data + edits).map { String(format: "%02x", $0) }.joined()
            }
            lock.lock(); values[key] = value; lock.unlock()
            return value == signature.expected
        }
    }
    private let documents: [Document]
    private let applications: [UUID: String]
    private let versions: Versions
    public func nextExpiry(after now: Date = .now) -> Date? {
        documents.compactMap(\.validUntil).filter { $0 > now }.min()
    }

    public init(state: RecallState, matters: [MatterFile], now: Date = .now) {
        let sources = state.captures.filter { !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }
        let live = Set(sources.map(\.id))
        let invalid = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let usable = live.subtracting(invalid)
        applications = Dictionary(sources.map { ($0.id, $0.sourceAppName ?? "") }, uniquingKeysWith: { _, last in last })
        versions = Versions(state, sources: sources)
        var rows: [Document] = []
        func permitted(_ ids: Set<UUID>) -> Bool { !ids.isEmpty && ids.isSubset(of: usable) }
        for source in sources {
            if Task.isCancelled { break }
            guard source.isMemoryEvidenceArchive != true, source.eventTemplate != .dailyReview, source.memoryDirective == nil else { continue }
            let title = source.correctedText.map { String($0.prefix(96)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ChatSourceRow(source).title
            rows.append(Document(hit: MemorySearchHit(id: "record:" + source.id.uuidString,
                title: title.isEmpty ? (source.sourceAppName ?? "原始记录") : title, detail: "", kind: "原始记录",
                date: source.createdAt, sourceIDs: [source.id], destination: .record(source.id)),
                text: source.correctedText ?? source.ocrText))
        }
        // Topic matches use each event's own date and text, rather than its latest activity date.
        for file in matters {
            if Task.isCancelled { break }
            for event in file.events where permitted(Set(event.evidenceIDs)) {
                rows.append(Document(hit: .init(id: "topic:" + file.id, title: file.title, detail: "", kind: "记忆主题",
                    date: event.date, sourceIDs: Set(event.evidenceIDs), destination: .topic(file.id)), text: event.detail))
            }
        }
        for report in state.dailySummaries {
            if Task.isCancelled { break }
            let itemIDs = Set(report.items.flatMap(\.evidenceIDs))
            let ids = itemIDs.isEmpty ? Set(report.sourceCaptureIDs) : itemIDs
            guard permitted(ids) else { continue }
            let content = report.items.isEmpty ? report.content :
                report.items.map { $0.title + "\n" + $0.detail }.joined(separator: "\n")
            let signatures = report.items.flatMap { item in
                (item.knowledge?.sourceVersions ?? [:]).compactMap { key, value -> Signature? in
                    UUID(uuidString: key).map { Signature(id: $0, expected: value, kind: .daily) }
                }
            }
            rows.append(Document(hit: .init(id: "daily:" + report.id.uuidString,
                title: report.day.formatted(date: .abbreviated, time: .omitted) + " · " + RecallLocalization.text("每日回顾"),
                detail: "", kind: "每日回顾", date: report.day, sourceIDs: ids, destination: .daily(report.id)),
                text: (report.modelOverview ?? "") + "\n" + content, signatures: signatures))
        }
        for report in state.weeklyReports where report.isReadable && permitted(report.sourceIDs) {
            if Task.isCancelled { break }
            let signatures = report.sourceVersions.map { Signature(id: $0.key, expected: $0.value, kind: $0.value.hasPrefix("memory2:") ? .weekly : .legacy) }
            rows.append(Document(hit: .init(id: "review:" + report.id.uuidString, title: report.displayName, detail: "",
                kind: "周期回顾", date: report.period.start, sourceIDs: report.sourceIDs, destination: .review(report.id), endDate: report.period.end),
                text: report.markdown, signatures: signatures))
        }
        for reminder in state.reminders where permitted(Set(reminder.sourceCaptureIDs)) || (reminder.origin == .manual && reminder.sourceCaptureIDs.isEmpty) {
            if Task.isCancelled { break }
            rows.append(Document(hit: .init(id: "reminder:" + reminder.id.uuidString, title: reminder.title, detail: "", kind: "提醒",
                date: reminder.dueAt ?? reminder.createdAt, sourceIDs: Set(reminder.sourceCaptureIDs), destination: .reminder(reminder.id)),
                text: reminder.detail))
        }
        for claim in state.memoryKnowledge.claims where claim.usable(at: now) && claim.scope != .conversation
            && MemoryLibraryCategory.all.includes(claim.kind) && permitted(Set(claim.sourceIDs)) {
            if Task.isCancelled { break }
            let signatures = claim.evidence.map { Signature(id: $0.captureID, expected: $0.sourceVersion, kind: .memory) }
            rows.append(Document(hit: .init(id: "knowledge:" + claim.id.uuidString, title: claim.title, detail: "", kind: "长期记忆",
                date: claim.date, sourceIDs: Set(claim.sourceIDs), destination: .knowledge(claim.id)),
                text: claim.content, signatures: signatures, validUntil: claim.validUntil))
        }
        documents = rows
    }

    public func search(_ text: String, start: Date? = nil, end: Date? = nil, app: String? = nil, topicSources: Set<UUID>? = nil, limit: Int = 50) -> [MemorySearchHit] {
        (try? result(for: GlobalMemorySearchQuery(text: text, start: start, end: end, app: app, topicSources: topicSources), limit: limit)) ?? []
    }
    public func result(for query: GlobalMemorySearchQuery, limit: Int = 50, now: Date = .now) throws -> [MemorySearchHit] {
        try Task.checkCancellation()
        guard query.hasCriteria, limit > 0, query.start == nil || query.end == nil || query.start! < query.end! else { return [] }
        let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var matched: [(Document, Bool)] = []
        for document in documents {
            try Task.checkCancellation()
            let row = document.hit
            guard document.validUntil.map({ $0 > now }) ?? true else { continue }
            if let last = row.endDate {
                guard (query.start == nil || last > query.start!) && (query.end == nil || row.date < query.end!) else { continue }
            } else {
                guard (query.start == nil || row.date >= query.start!) && (query.end == nil || row.date < query.end!) else { continue }
            }
            guard query.app == nil || row.sourceIDs.contains(where: { applications[$0] == query.app! }),
                  query.topicSources == nil || !row.sourceIDs.isDisjoint(with: query.topicSources!),
                  terms.allSatisfy({ row.title.range(of: $0, options: options) != nil || document.text.range(of: $0, options: options) != nil }) else { continue }
            matched.append((document, !query.text.isEmpty && row.title.range(of: query.text, options: options) != nil))
        }
        matched.sort {
            if $0.1 != $1.1 { return $0.1 }
            let a = $0.0.hit, b = $1.0.hit
            return a.date == b.date ? a.id < b.id : a.date > b.date
        }
        var seen = Set<String>(), hits: [MemorySearchHit] = []
        for (document, _) in matched {
            try Task.checkCancellation()
            guard !seen.contains(document.hit.id), document.signatures.allSatisfy(versions.matches) else { continue }
            seen.insert(document.hit.id)
            var row = document.hit; row.detail = Self.snippet(document.text, terms: terms)
            hits.append(row)
            if hits.count >= limit { break }
        }
        return hits
    }
    private static func snippet(_ text: String, terms: [String]) -> String {
        let match = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.min { $0.lowerBound < $1.lowerBound }
        let start = match.flatMap { text.index($0.lowerBound, offsetBy: -64, limitedBy: text.startIndex) } ?? text.startIndex
        let end = text.index(start, offsetBy: 300, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
    }
}

