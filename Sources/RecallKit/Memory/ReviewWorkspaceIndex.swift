import Foundation

/// Built once on the workspace worker. UI queries never read OCR or scan captures per topic.
public struct ReviewCategoryIndex: Sendable {
    private let overrides: [String: ReviewCategory]
    private let notes: [UUID: (date: Date, ordinal: Int, category: ReviewCategory)]

    public init(state: RecallState) {
        var values = state.reviewCategories
        for group in state.topicGroups {
            let categories = Set(group.memberIDs.compactMap { state.reviewCategories[$0] })
            if categories.contains(.personal) { values[group.id] = .personal }
            else if categories.contains(.learning) { values[group.id] = .learning }
            else if categories == [.work] { values[group.id] = .work }
        }
        overrides = values
        notes = Dictionary(uniqueKeysWithValues: state.captures.enumerated().compactMap { ordinal, source in
            guard let category = source.manualMatter?.reviewCategory, category != .unclassified else { return nil }
            return (source.id, (date: source.createdAt, ordinal: ordinal, category: category))
        })
    }

    public func category(for file: MatterFile) -> ReviewCategory {
        if let selected = overrides[file.id] { return selected }
        // Compute the source set once, not once for every record in the archive.
        let latest = Set(file.events.flatMap(\.evidenceIDs)).compactMap { id -> (date: Date, ordinal: Int, category: ReviewCategory)? in
            guard let note = notes[id] else { return nil }
            return note
        }.max { a, b in a.date == b.date ? a.ordinal < b.ordinal : a.date < b.date }
        if let latest { return latest.category }
        if file.id.hasPrefix("life:") {
            return ["阅读", "学习", "练习"].contains(where: file.title.hasPrefix) ? .learning : .personal
        }
        return .unclassified
    }
}

/// Compact rows for the range/scope controls; no paragraphs, events or source text in the view.
public struct ReviewTopicSummary: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let category: ReviewCategory
    private let dates: [Date]

    init(file: MatterFile, categories: ReviewCategoryIndex) {
        id = file.id; title = file.title; category = categories.category(for: file)
        dates = Array(Set(file.events.map(\.date))).sorted()
    }

    public func occurs(in period: ReviewPeriod) -> Bool {
        let i = dates.reviewLowerBound(period.start)
        return i < dates.count && dates[i] < period.end
    }
}

public struct ReviewRangePreview: Sendable {
    public let coverage: ReviewRecordCoverage
    public let topicCount: Int
    public let eligibleTopicCount: Int
}

public struct ReviewWorkspaceIndex: Sendable {
    public let topics: [ReviewTopicSummary]
    private let recordDates: [Date]
    private let textDates: [Date]

    public init() { topics = []; recordDates = []; textDates = [] }

    public init(state: RecallState, topics files: [MatterFile]) {
        let categories = ReviewCategoryIndex(state: state)
        topics = files.map { ReviewTopicSummary(file: $0, categories: categories) }
        let invalid = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        var eventDates: [UUID: Date] = [:], completed: Set<UUID> = []
        for correction in state.matterCorrections {
            for id in correction.evidenceIDs {
                if correction.kind == .eventDate { eventDates[id] = correction.eventAt }
                if correction.kind == .completed { completed.insert(id) }
            }
        }
        var records: [Date] = [], text: [Date] = []
        for source in state.captures {
            guard !invalid.contains(source.id), source.memoryDirective == nil, source.eventTemplate != .dailyReview,
                  !state.privacy.excludedBundleIdentifiers.contains(source.sourceBundleIdentifier ?? "") else { continue }
            let date = eventDates[source.id] ?? source.createdAt
            records.append(date)
            if completed.contains(source.id) || source.ocrText.contains(where: { !$0.isWhitespace }) { text.append(date) }
        }
        recordDates = records.sorted(); textDates = text.sorted()
    }

    public func coverage(in period: ReviewPeriod) -> ReviewRecordCoverage {
        ReviewRecordCoverage(totalRecords: recordDates.count, periodRecords: recordDates.reviewCount(in: period),
            textRecords: textDates.reviewCount(in: period), latestRecordAt: recordDates.last)
    }

    /// Binary date checks over compact metadata. Cost is independent of OCR length/source count.
    public func preview(in period: ReviewPeriod, kind: ReviewTemplateKind, scope: ReviewScope) -> ReviewRangePreview {
        var count = 0, eligible = 0
        for topic in topics where topic.occurs(in: period) {
            count += 1
            if kind.includes(category: topic.category, topicID: topic.id, scope: scope) { eligible += 1 }
        }
        return ReviewRangePreview(coverage: coverage(in: period), topicCount: count, eligibleTopicCount: eligible)
    }
}

private extension Array where Element == Date {
    func reviewLowerBound(_ date: Date) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = low + (high - low) / 2
            if self[mid] < date { low = mid + 1 } else { high = mid }
        }
        return low
    }
    func reviewCount(in period: ReviewPeriod) -> Int {
        guard period.start < period.end else { return 0 }
        return reviewLowerBound(period.end) - reviewLowerBound(period.start)
    }
}

public struct MemoryWorkspaceProjection: Sendable {
    public let revision: UUID
    public let matters: [MatterFile]
    public let review: ReviewWorkspaceIndex
    public let summary: MemoryOrganizationSummary
    public let sources: [UUID: CaptureRecord]
}

/// Shared across tab lifetimes. Unrelated chat/report/settings refreshes do not reparse the archive.
/// Exact inputs, rather than counts/latest dates, also detect edits and deletions with equal totals.
public actor MemoryWorkspaceCache {
    private struct Input: Equatable {
        let captures: [CaptureRecord]
        let episodes: [WorkEpisode]
        let corrections: [MatterCorrection]
        let groups: [MemoryTopicGroup]
        let claims: [MemoryClaim]
        let versions: [String: String]
        let initialized: Bool
        let organizationVersion: Int?
        let usableClaims: Set<UUID>
        let categories: [String: ReviewCategory]
        let excludedApps: Set<String>
        let timeZone: String
        init(_ state: RecallState, now: Date) {
            captures = state.captures; episodes = state.episodes; corrections = state.matterCorrections; groups = state.topicGroups
            claims = state.memoryKnowledge.claims; versions = state.memoryKnowledge.sourceVersions
            initialized = state.memoryKnowledge.updatedAt != nil; organizationVersion = state.memoryKnowledge.organizationVersion
            usableClaims = Set(claims.filter { $0.usable(at: now) }.map(\.id))
            categories = state.reviewCategories; excludedApps = state.privacy.excludedBundleIdentifiers
            timeZone = TimeZone.current.identifier
        }
    }
    private var input: Input?
    private var cached: MemoryWorkspaceProjection?
    public init() {}

    public func prepare(in state: RecallState) throws -> MemoryWorkspaceProjection {
        try Task.checkCancellation()
        let next = Input(state, now: .now)
        if next == input, let cached { return cached }
        let matters = MatterMemoryEngine().files(in: state)
        try Task.checkCancellation()
        let topics = WeeklyReviewEngine().topics(in: state, matterFiles: matters)
        try Task.checkCancellation()
        let result = MemoryWorkspaceProjection(revision: UUID(), matters: matters,
            review: ReviewWorkspaceIndex(state: state, topics: topics), summary: MemoryOrganizationSummary(state: state),
            sources: Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0) }))
        try Task.checkCancellation()
        input = next; cached = result
        return result
    }
}
