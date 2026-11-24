import Foundation
@preconcurrency import EventKit

/// Off by default. When on, Recall reads (never writes) upcoming calendar events and, a few minutes
/// before each one, gathers saved records that mention the event title or its attendees.
public struct MeetingBriefSettings: Codable, Hashable, Sendable {
    public var enabled = false
    public var minutesBefore = 10
    /// Event identifiers already briefed, so one meeting is never announced twice. Capped.
    public var briefedEventKeys: [String] = []
    public init() {}
}

/// Only what Recall needs from a calendar event. Notes, locations and URLs are never read.
public struct CalendarEventSummary: Sendable, Equatable {
    public var key: String
    public var title: String
    public var start: Date
    public var attendees: [String]
    public init(key: String, title: String, start: Date, attendees: [String] = []) {
        self.key = key; self.title = title; self.start = start; self.attendees = attendees
    }
}

public struct MeetingBrief: Sendable, Equatable {
    public var event: CalendarEventSummary
    public var records: [CaptureRecord]
    public var openReminders: [ReminderCandidate]
}

public enum MeetingBriefEngine {
    public static func brief(for event: CalendarEventSummary, in state: RecallState, limit: Int = 6) -> MeetingBrief {
        let keywords = (QuestionTerms.topicTerms(event.title) + event.attendees.map { $0.lowercased() })
            .filter { $0.count >= 2 }
        let records = EvidenceAccess.records(state).filter { record in
            let text = (record.searchableText + " " + (record.windowTitle ?? "")).lowercased()
            return keywords.contains { text.contains($0.lowercased()) }
        }.sorted { $0.createdAt > $1.createdAt }
        let sourceIDs = Set(records.map(\.id))
        let reminders = state.reminders.filter { $0.status.isAction && !sourceIDs.isDisjoint(with: $0.sourceCaptureIDs) }
        return MeetingBrief(event: event, records: Array(records.prefix(limit)), openReminders: Array(reminders.prefix(3)))
    }

    /// Events starting within the brief window that were not briefed yet.
    public static func due(_ events: [CalendarEventSummary], settings: MeetingBriefSettings, now: Date = .now) -> [CalendarEventSummary] {
        let window = TimeInterval(max(1, settings.minutesBefore) * 60)
        return events.filter { $0.start > now && $0.start.timeIntervalSince(now) <= window && !settings.briefedEventKeys.contains($0.key) }
    }
}

public protocol CalendarReading: Sendable {
    func authorized() -> Bool
    func requestAccess() async -> Bool
    func events(from start: Date, to end: Date) -> [CalendarEventSummary]
}

public final class EventKitCalendarReader: CalendarReading, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}
    public func authorized() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }
    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }
    public func events(from start: Date, to end: Date) -> [CalendarEventSummary] {
        guard authorized() else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).filter { !$0.isAllDay }.map { event in
            CalendarEventSummary(key: (event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString) + "@" + String(Int(event.startDate.timeIntervalSince1970)),
                title: event.title ?? "", start: event.startDate,
                attendees: (event.attendees ?? []).compactMap(\.name).filter { !$0.isEmpty })
        }
    }
}

public extension FileMemoryStore {
    func updateMeetingBriefSettings(enabled: Bool, minutesBefore: Int) throws {
        let before = state
        state.meetingBriefSettings.enabled = enabled
        state.meetingBriefSettings.minutesBefore = min(max(minutesBefore, 1), 60)
        if !enabled { state.meetingBriefSettings.briefedEventKeys = [] }
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = before; throw error }
    }
    func markMeetingBriefed(_ key: String) throws {
        let before = state
        state.meetingBriefSettings.briefedEventKeys.append(key)
        if state.meetingBriefSettings.briefedEventKeys.count > 100 { state.meetingBriefSettings.briefedEventKeys.removeFirst(state.meetingBriefSettings.briefedEventKeys.count - 100) }
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = before; throw error }
    }
}
