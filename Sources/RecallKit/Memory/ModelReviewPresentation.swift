import Foundation

public extension ModelReviewResult {
    func dailySummary(day: Date, now: Date = .now) -> DailySummary {
        let values = items.compactMap { item -> DailySummaryItem? in
            guard let section = DailySummarySection(rawValue: item.section) else { return nil }
            return DailySummaryItem(section: section, title: item.title, detail: item.detail, evidenceIDs: sourceIDs(for: item))
        }
        let actions = items.filter { $0.section == "actions" }.map { item in
            DailySummaryTodo(title: item.title, detail: item.detail, sourceCaptureIDs: sourceIDs(for: item), priority: .normal)
        }
        var report = DailySummary(day: day, createdAt: now, content: DailySummaryItemParser.reviewedMarkdown(from: values),
            sourceCaptureIDs: Array(sourceVersions.keys).sorted { $0.uuidString < $1.uuidString },
            todos: actions, generationKind: .cloud, items: values)
        report.modelCoverage = coverage; report.modelOverview = overview
        report.items = DailySummaryItemParser.modelValidated(values); report.todos = actions
        return report
    }
    func weeklyReport(period: ReviewPeriod, template: ReviewTemplate, scope: ReviewScope, in state: RecallState, now: Date = .now) -> WeeklyReport {
        let rows = items.compactMap { item -> ReviewItem? in
            guard let section = ReviewSection(rawValue: item.section) else { return nil }
            let evidence = facts.filter { item.factIDs.contains($0.id) }
            let excerpts = evidence.map { fact in
                ReviewExcerpt(id: MatterEvidence.eventID(source: fact.sourceIDs.first ?? UUID(), topic: fact.id, ordinal: 0),
                    date: fact.recordedAt, text: fact.detail, status: Self.status(fact.status), sourceIDs: fact.sourceIDs,
                    eventTimeKnown: false)
            }
            return ReviewItem(id: "model:" + CaptureUnderstandingEngine.digest(item.section + item.title + item.factIDs.joined()),
                title: item.title, category: template.kind.requiresWorkScope ? .work : template.kind == .learning ? .learning : .unclassified,
                section: section, previous: nil, excerpts: excerpts, featuredIDs: excerpts.map(\.id), nextAction: nil, nextActionSourceIDs: [], narrative: ReviewNarrative(title: item.title, summary: item.detail, evidenceIDs: excerpts.map(\.id)))
        }
        var report = WeeklyReport(createdAt: now, updatedAt: now, period: period, template: template, scope: scope,
            items: rows, sourceVersions: sourceVersions, modelAssisted: true)
        report.modelCoverage = coverage; report.modelOverview = overview
        report.digestTopicIDs = rows.map(\.id); report.feedbackRevision = SummaryFeedbackLearning.revision(in: state)
        report.topicGrouping = state.topicGroups
        return report
    }
    private static func status(_ value: String) -> WorkEpisodeStatus {
        switch value {
        case "completed": .completed
        case "pending": .pending
        case "inProgress", "progressed": .progressed
        case "blocked": .blocked
        default: .explored
        }
    }
}

public struct TopicReviewPoint: Codable, Hashable, Sendable {
    public var title: String
    public var detail: String
    public var section: String
    public var sourceIDs: [UUID]
}
public struct TopicModelReview: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var overview: String
    public var points: [TopicReviewPoint]
    public var sourceVersions: [UUID: String]
    public var coverage: ModelReviewCoverage
    public init(topicID: String, result: ModelReviewResult, now: Date = .now) {
        id = topicID; createdAt = now; overview = result.overview; sourceVersions = result.sourceVersions; coverage = result.coverage
        points = result.items.map { TopicReviewPoint(title: $0.title, detail: $0.detail, section: $0.section, sourceIDs: result.sourceIDs(for: $0)) }
    }
    public func sourcesUnchanged(in state: RecallState) -> Bool {
        !sourceVersions.isEmpty && sourceVersions.allSatisfy { id, version in
            WeeklyReviewEngine.sourceVersion(id: id, state: state) == version
                && state.captures.contains { $0.id == id && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }
        }
    }
}

extension FileMemoryStore {
    public func commitTopicReview(_ report: TopicModelReview) throws {
        try Task.checkCancellation()
        guard report.sourcesUnchanged(in: state) else { throw ModelReviewError.changed }
        let before = state
        state.topicReviews.removeAll { $0.id == report.id }; state.topicReviews.append(report)
        do { try persist() } catch { state = before; throw error }
    }
}
