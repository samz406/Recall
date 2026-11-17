import Foundation

/// Pure timing rules shared by the app, notification scheduler and verifier.
/// A repeating series is anchored at its first occurrence; snoozing is a separate one-off delay.
public enum ReminderTimeline {
    /// Months whose anchor day can be missing are delivered as explicit one-off requests.
    public static let monthlyLookahead = 3
    public static let historyRetentionDismissedDays = 90
    public static let historyRetentionClosedDays = 180
    public static let historyLimit = 1_000

    public static func anchor(of reminder: ReminderCandidate) -> Date? {
        reminder.recurrenceAnchor ?? reminder.dueAt
    }
    /// When the reminder next needs attention: an active snooze wins over the regular time.
    public static func effectiveDueAt(_ reminder: ReminderCandidate) -> Date? {
        reminder.snoozedUntil ?? reminder.dueAt
    }
    public static func isOverdue(_ reminder: ReminderCandidate, now: Date = .now) -> Bool {
        reminder.status.needsNotification && (effectiveDueAt(reminder) ?? .distantFuture) < now
    }

    /// Sets a new regular time. Starts a fresh series anchored at that time.
    public static func rescheduling(_ reminder: ReminderCandidate, dueAt: Date, recurrence: ReminderRecurrence, now: Date = .now) -> ReminderCandidate {
        var updated = reminder
        updated.dueAt = dueAt; updated.recurrence = recurrence
        updated.recurrenceAnchor = recurrence == .none ? nil : dueAt
        updated.snoozedUntil = nil; updated.status = .scheduled
        updated.scheduledAt = now; updated.updatedAt = now
        return updated
    }

    /// Delays only the current occurrence; the series keeps its regular time.
    public static func snoozing(_ reminder: ReminderCandidate, until date: Date, now: Date = .now) -> ReminderCandidate {
        var updated = reminder
        if updated.recurrence != .none && updated.recurrenceAnchor == nil { updated.recurrenceAnchor = updated.dueAt }
        updated.snoozedUntil = date; updated.status = .snoozed
        updated.snoozeCount += 1; updated.updatedAt = now
        return updated
    }

    /// Completes one occurrence. A repeating series moves to the next occurrence on its own schedule,
    /// however late the completion was; a one-off reminder closes.
    public static func completing(_ reminder: ReminderCandidate, now: Date = .now, calendar: Calendar = .current) -> ReminderCandidate {
        var updated = reminder
        updated.completedAt = now; updated.updatedAt = now; updated.snoozedUntil = nil
        if reminder.recurrence != .none, let due = reminder.dueAt, let anchor = anchor(of: reminder),
           let next = reminder.recurrence.occurrence(after: max(due, now), anchor: anchor, calendar: calendar) {
            updated.recurrenceAnchor = anchor; updated.dueAt = next
            updated.status = .scheduled; updated.closedAt = nil
        } else {
            updated.status = .completed; updated.closedAt = now
        }
        return updated
    }

    /// Follows the system's repeating delivery. Today's missed occurrence stays visible as overdue
    /// until the day ends; earlier ones advance. An elapsed snooze on a series returns to the series.
    public static func rolledForward(_ reminder: ReminderCandidate, now: Date = .now, calendar: Calendar = .current) -> ReminderCandidate {
        guard reminder.status.needsNotification, reminder.recurrence != .none,
              let due = reminder.dueAt, let anchor = anchor(of: reminder) else { return reminder }
        var updated = reminder
        updated.recurrenceAnchor = anchor
        if let snooze = updated.snoozedUntil, snooze <= now { updated.snoozedUntil = nil; updated.status = .scheduled }
        let today = calendar.startOfDay(for: now)
        if updated.snoozedUntil == nil, due < today {
            if let latest = reminder.recurrence.latestOccurrence(atOrBefore: now, anchor: anchor, calendar: calendar), latest >= today {
                updated.dueAt = latest
            } else if let next = reminder.recurrence.occurrence(after: now, anchor: anchor, calendar: calendar) {
                updated.dueAt = next
            }
        }
        return updated
    }

    /// Completed, cancelled and dismissed records expire on a fixed schedule instead of growing forever.
    public static func retainsHistory(_ reminder: ReminderCandidate, now: Date = .now) -> Bool {
        switch reminder.status {
        case .dismissed:
            return now.timeIntervalSince(reminder.dismissedUntil ?? reminder.closedAt ?? reminder.updatedAt) < Double(historyRetentionDismissedDays) * 86_400
        case .completed, .cancelled:
            return now.timeIntervalSince(reminder.closedAt ?? reminder.completedAt ?? reminder.updatedAt) < Double(historyRetentionClosedDays) * 86_400
        default: return true
        }
    }

    public struct Request: Hashable, Sendable {
        public enum Trigger: Hashable, Sendable { case once(Date), repeating(DateComponents) }
        public var identifier: String
        public var trigger: Trigger
    }
    public static func identifiers(for id: UUID) -> [String] {
        [id.uuidString, id.uuidString + "#snooze"] + (0..<monthlyLookahead).map { id.uuidString + "#m\($0)" }
    }
    public static func reminderID(fromRequest identifier: String) -> UUID? {
        UUID(uuidString: String(identifier.prefix(36)))
    }

    /// Exactly the system requests a reminder should have. Past one-off dates are omitted.
    public static func requests(for reminder: ReminderCandidate, now: Date = .now, calendar: Calendar = .current) -> [Request] {
        guard reminder.status.needsNotification, let due = reminder.dueAt else { return [] }
        let id = reminder.id.uuidString
        var result: [Request] = []
        if let snooze = reminder.snoozedUntil, snooze > now {
            result.append(Request(identifier: reminder.recurrence == .none ? id : id + "#snooze", trigger: .once(snooze)))
            if reminder.recurrence == .none { return result }
        }
        let anchor = anchor(of: reminder) ?? due
        switch reminder.recurrence {
        case .none:
            if due > now { result.append(Request(identifier: id, trigger: .once(due))) }
        case .daily:
            result.append(Request(identifier: id, trigger: .repeating(calendar.dateComponents([.hour, .minute], from: anchor))))
        case .weekly:
            result.append(Request(identifier: id, trigger: .repeating(calendar.dateComponents([.weekday, .hour, .minute], from: anchor))))
        case .monthly where calendar.component(.day, from: anchor) <= 28:
            result.append(Request(identifier: id, trigger: .repeating(calendar.dateComponents([.day, .hour, .minute], from: anchor))))
        case .monthly:
            // A calendar trigger for the 29th–31st silently skips shorter months. Use explicit dates,
            // topped up whenever the app refreshes.
            var date = now
            for index in 0..<monthlyLookahead {
                guard let next = reminder.recurrence.occurrence(after: date, anchor: anchor, calendar: calendar) else { break }
                result.append(Request(identifier: id + "#m\(index)", trigger: .once(next))); date = next
            }
        }
        return result
    }
}

extension FileMemoryStore {
    /// Local-only maintenance on every refresh: follow repeating delivery and expire old history.
    @discardableResult
    public func maintainReminders(now: Date = .now) throws -> Bool {
        let previous = state
        state.reminders = state.reminders.map { ReminderTimeline.rolledForward($0, now: now) }
            .filter { ReminderTimeline.retainsHistory($0, now: now) }
        let history = state.reminders.filter(\.status.isHistory)
        if history.count > ReminderTimeline.historyLimit {
            let keep = Set(history.sorted { ReminderHistoryRow.date(of: $0) > ReminderHistoryRow.date(of: $1) }
                .prefix(ReminderTimeline.historyLimit).map(\.id))
            state.reminders.removeAll { $0.status.isHistory && !keep.contains($0.id) }
        }
        guard state.reminders != previous.reminders else { return false }
        do { try persistReviewState() } catch { state = previous; throw error }
        return true
    }

    /// Confirms every pending candidate into today's list in one write.
    @discardableResult
    public func addAllProposedToToday(now: Date = .now, timeZone: TimeZone = .current) throws -> Int {
        let allowed = Set(EvidenceAccess.records(state).map(\.id))
        let previous = state
        var count = 0
        for i in state.reminders.indices where state.reminders[i].status == .proposed && Set(state.reminders[i].sourceCaptureIDs).isSubset(of: allowed) {
            state.reminders[i].status = .planned; state.reminders[i].acceptedAt = now
            state.reminders[i].plannedForDay = LocalDay(now, timeZone: timeZone)
            state.reminders[i].scheduledAt = nil; state.reminders[i].dueAt = nil; state.reminders[i].updatedAt = now
            count += 1
        }
        guard count > 0 else { return 0 }
        do { try persistReviewState() } catch { state = previous; throw error }
        return count
    }
}
