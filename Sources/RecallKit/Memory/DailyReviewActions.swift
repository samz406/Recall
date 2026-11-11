import Foundation

/// One presentation pass: model-validated rows must not be erased by legacy action heuristics.
public enum DailyReviewPresentation {
    public static func key(_ text: String) -> String {
        DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(from: DailySummaryContentFormatter.removingCitationMarkers(from: text))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
    public static func action(for item: DailySummaryItem, in summary: DailySummary) -> DailySummaryTodo? {
        if let id = item.actionCandidateID, let action = summary.todos.first(where: { $0.id == id }) { return action }
        let matches = summary.todos.filter { !key(item.title).isEmpty && key($0.title) == key(item.title) }
        return matches.count == 1 ? matches[0] : nil
    }
    public static func reminder(for action: DailySummaryTodo, item: DailySummaryItem, in state: RecallState) -> ReminderCandidate? {
        state.reminders.first { $0.id == action.id } ?? state.reminders.first {
            key($0.title) == key(action.title) && !Set($0.sourceCaptureIDs).isDisjoint(with: action.sourceCaptureIDs + item.evidenceIDs)
        }
    }
    public static func items(in summary: DailySummary, state: RecallState) -> [DailySummaryItem] {
        let live = Set(state.captures.filter { !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }.map(\.id))
        let rows = summary.modelCoverage == nil ? DailySummaryItemParser.sanitized(summary.items) : DailySummaryItemParser.modelValidated(summary.items)
        return rows.filter { item in
            guard !(key(item.title) + key(item.detail)).isEmpty, item.evidenceIDs.contains(where: live.contains) else { return false }
            guard item.section == .actions else { return true }
            guard item.knowledge?.status != "completed" else { return false }
            if let action = action(for: item, in: summary) {
                guard action.status == .pending || action.status == .inProgress else { return false }
                if let reminder = reminder(for: action, item: item, in: state), reminder.status.isHistory { return false }
            }
            return true
        }
    }
}

public enum DailyReviewActionError: LocalizedError {
    case changed
    public var errorDescription: String? { RecallLocalization.both("这条待办或来源已变化，请刷新后重试。", "This action or its sources changed. Refresh and retry.") }
}

/// Prepare notification changes before the atomic write, and reject stale saves after an await.
public struct DailyReviewActionCompletion: Equatable, Sendable {
    public let summaryID: UUID
    public let itemID: UUID
    public let actionID: UUID
    public let previousReminder: ReminderCandidate?
    public let reminder: ReminderCandidate
    public let sourceVersions: [UUID: String]
    public let completedAt: Date
    public var schedulesNextOccurrence: Bool { reminder.status == .scheduled }

    public init(summaryID: UUID, itemID: UUID, state: RecallState, now: Date = .now) throws {
        guard let summary = state.dailySummaries.first(where: { $0.id == summaryID }),
              let item = DailyReviewPresentation.items(in: summary, state: state).first(where: { $0.id == itemID && $0.section == .actions }),
              let action = DailyReviewPresentation.action(for: item, in: summary), action.status == .pending || action.status == .inProgress else { throw DailyReviewActionError.changed }
        let ids = Set(action.sourceCaptureIDs + item.evidenceIDs)
        let invalid = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let sources = state.captures.filter { ids.contains($0.id) && !invalid.contains($0.id) && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }
        guard !ids.isEmpty, Set(sources.map(\.id)) == ids else { throw DailyReviewActionError.changed }
        self.summaryID = summaryID; self.itemID = itemID; actionID = action.id; completedAt = now
        sourceVersions = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, CaptureUnderstandingEngine.sourceVersion($0, in: state)) })
        previousReminder = DailyReviewPresentation.reminder(for: action, item: item, in: state)
        var updated = previousReminder ?? ReminderCandidate(id: action.id, title: item.title, detail: item.detail,
            sourceCaptureIDs: ids.sorted { $0.uuidString < $1.uuidString }, confidence: 1, createdAt: now, updatedAt: now,
            semanticKey: DailyReviewPresentation.key(item.title))
        updated.completedAt = now; updated.updatedAt = now
        if let due = updated.dueAt, updated.recurrence != .none, let next = updated.recurrence.nextDate(after: max(due, now)) {
            updated.dueAt = next; updated.status = .scheduled; updated.closedAt = nil
        } else { updated.status = .completed; updated.closedAt = now }
        reminder = updated
    }
}

extension FileMemoryStore {
    @discardableResult
    public func completeDailyReviewAction(_ completion: DailyReviewActionCompletion) throws -> Bool {
        guard let i = state.dailySummaries.firstIndex(where: { $0.id == completion.summaryID }),
              let j = state.dailySummaries[i].todos.firstIndex(where: { $0.id == completion.actionID }) else { throw DailyReviewActionError.changed }
        if state.dailySummaries[i].todos[j].status == .completed { return false }
        guard try DailyReviewActionCompletion(summaryID: completion.summaryID, itemID: completion.itemID, state: state, now: completion.completedAt) == completion else { throw DailyReviewActionError.changed }
        let previous = state
        state.dailySummaries[i].todos[j].status = .completed
        state.dailySummaries[i].todos[j].updatedAt = completion.completedAt
        if let r = state.reminders.firstIndex(where: { $0.id == completion.reminder.id }) { state.reminders[r] = completion.reminder }
        else { state.reminders.insert(completion.reminder, at: 0) }
        let key = completion.reminder.semanticKey.isEmpty ? DailyReviewPresentation.key(completion.reminder.title) : completion.reminder.semanticKey
        state.reminderLearningProfile.record(.completed, semanticKey: key)
        do { try persistReviewState(indexChanged: true) } catch { state = previous; throw error }
        return true
    }
}
