import Foundation
import RecallKit

/// The production implementation is the system scheduler; verification uses an in-memory substitute.
@MainActor protocol ReminderCreationScheduling {
    func requestAuthorization() async throws -> Bool
    func schedule(_ reminder: ReminderCandidate) async throws
    func cancel(_ reminder: ReminderCandidate)
    /// Current permission without prompting; nil when unknown or unavailable on this host.
    func notificationsAllowed() async -> Bool?
    func deliveryStates(for reminders: [ReminderCandidate]) async throws -> [UUID: ReminderDeliveryState]
}
extension ReminderCreationScheduling {
    func notificationsAllowed() async -> Bool? { nil }
    func deliveryStates(for reminders: [ReminderCandidate]) async throws -> [UUID: ReminderDeliveryState] { [:] }
}
extension LocalNotificationScheduler: ReminderCreationScheduling {
    func notificationsAllowed() async -> Bool? { await authorizationGranted() }
}

/// Shared by the reminder card, the notification buttons and the menu bar.
enum ReminderSnoozeOption: CaseIterable, Identifiable {
    case hour, tonight, tomorrow, nextMonday
    var id: Self { self }
    func title(preferredHour: Int) -> String {
        switch self {
        case .hour: RecallLocalization.both("1 小时后", "In 1 hour")
        case .tonight: RecallLocalization.both("今晚 20:00", "Tonight 20:00")
        case .tomorrow: RecallLocalization.both(String(format: "明天 %02d:00", preferredHour), String(format: "Tomorrow %02d:00", preferredHour))
        case .nextMonday: RecallLocalization.both(String(format: "下周一 %02d:00", preferredHour), String(format: "Next Monday %02d:00", preferredHour))
        }
    }
    func date(preferredHour: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour:
            return now.addingTimeInterval(60 * 60)
        case .tonight:
            return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(3_600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
            return calendar.date(bySettingHour: preferredHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .nextMonday:
            let start = calendar.startOfDay(for: now)
            let monday = calendar.nextDate(after: start, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? start.addingTimeInterval(7 * 86_400)
            return calendar.date(bySettingHour: preferredHour, minute: 0, second: 0, of: monday) ?? monday
        }
    }
    /// "Tonight" disappears once evening has passed.
    func isAvailable(now: Date = .now, calendar: Calendar = .current) -> Bool {
        self != .tonight || calendar.component(.hour, from: now) < 19
    }
}

struct ReminderCreationResult {
    let reminder: ReminderCandidate
    let notificationIssue: String?
    var message: String {
        if let notificationIssue {
            return RecallLocalization.both("已保存到‘待确认’，通知尚未安排。", "Saved to To confirm. Notifications are not scheduled. ") + notificationIssue
        }
        let date = reminder.dueAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return RecallLocalization.both("已保存到‘待处理’，将在 \(date) 提醒。", "Saved to Pending. Reminder scheduled for \(date).")
    }
}

enum ReminderCreationError: LocalizedError {
    case invalidInput, saveFailed, scheduleSaveFailed
    var errorDescription: String? {
        switch self {
        case .invalidInput: RecallLocalization.both("请输入提醒内容，并选择未来的时间。", "Enter a reminder and choose a future time.")
        case .saveFailed: RecallLocalization.both("提醒未能保存，请重试。输入内容已保留。", "Unable to save. Your input has been kept; please retry.")
        case .scheduleSaveFailed: RecallLocalization.both("通知安排未完成，请在待确认中重试。", "Notification scheduling was not completed. Retry from To confirm.")
        }
    }
}

/// Used both for the displayed ordering and for revealing a newly saved reminder on its actual page.
struct ReminderListLocation {
    let tab: Int
    let page: Int
    init?(id: UUID, reminders: [ReminderCandidate], pageSize: Int) {
        guard let row = reminders.first(where: { $0.id == id }) else { return nil }
        tab = row.status == .proposed ? 1 : (row.status.isHistory ? 2 : 0)
        let ordered = tab == 1 ? Self.proposed(reminders) : Self.active(reminders)
        page = ((ordered.firstIndex { $0.id == id } ?? 0) / max(1, pageSize)) + 1
    }
    static func proposed(_ reminders: [ReminderCandidate]) -> [ReminderCandidate] {
        reminders.filter { $0.status == .proposed }.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.dueAt != $1.dueAt { return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    static func active(_ reminders: [ReminderCandidate]) -> [ReminderCandidate] {
        reminders.filter { $0.status.isAction }.sorted {
            let left = ReminderTimeline.effectiveDueAt($0), right = ReminderTimeline.effectiveDueAt($1)
            if left != right { return (left ?? .distantFuture) < (right ?? .distantFuture) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
