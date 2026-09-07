import Foundation
import UserNotifications

public struct ReminderExtractor: Sendable {
    public init() {}

    public func candidates(from captures: [CaptureRecord], existing: [ReminderCandidate]) -> [ReminderCandidate] {
        let existingTitles = Set(existing.map { $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        let actionMarkers = ["todo", "待办", "需要", "记得", "截止", "回复", "follow up", "action item"]
        var result: [ReminderCandidate] = []

        for capture in captures where !capture.ocrText.isEmpty {
            let lines = capture.ocrText.split(whereSeparator: \ .isNewline).map(String.init)
            for line in lines {
                let compact = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard compact.count >= 5 else { continue }
                let lower = compact.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard actionMarkers.contains(where: { lower.contains($0) }) else { continue }
                let normalizedTitle = String(compact.prefix(120))
                let comparable = normalizedTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard !existingTitles.contains(comparable) && !result.contains(where: {
                    $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == comparable
                }) else { continue }
                result.append(ReminderCandidate(
                    title: normalizedTitle,
                    detail: "从 \(capture.sourceAppName ?? "记录") 的内容中识别出；创建前请确认。",
                    dueAt: inferredDueDate(in: compact, base: capture.createdAt),
                    sourceCaptureIDs: [capture.id],
                    confidence: compact.localizedCaseInsensitiveContains("截止") ? 0.82 : 0.64
                ))
            }
        }
        return result
    }

    private func inferredDueDate(in text: String, base: Date) -> Date? {
        let calendar = Calendar.current
        if text.contains("明天") { return calendar.date(byAdding: .day, value: 1, to: base) }
        if text.localizedCaseInsensitiveContains("tomorrow") { return calendar.date(byAdding: .day, value: 1, to: base) }
        if text.contains("下周") { return calendar.date(byAdding: .day, value: 7, to: base) }
        return nil
    }
}

@MainActor
public final class LocalNotificationScheduler {
    public init() {}

    public func requestAuthorization() async throws -> Bool {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                throw notificationError(from: error)
            }
        @unknown default:
            return false
        }
    }

    public func schedule(_ reminder: ReminderCandidate) async throws {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ReminderNotificationError.authorizationRequired
        }
        guard let dueAt = reminder.dueAt else { throw ReminderNotificationError.missingDueDate }
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.detail
        content.sound = .default
        content.userInfo = ["reminderID": reminder.id.uuidString]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueAt)
        let request = UNNotificationRequest(
            identifier: reminder.id.uuidString,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        do {
            try await center.add(request)
        } catch {
            throw notificationError(from: error)
        }

        guard try await deliveryStates(for: [reminder])[reminder.id] == .pending else {
            center.removePendingNotificationRequests(withIdentifiers: [reminder.id.uuidString])
            throw ReminderNotificationError.notificationSchedulingFailed
        }
    }

    /// 仅核验由 Recall 创建的通知标识；不读取或暴露其他应用的通知内容。
    public func deliveryStates(for reminders: [ReminderCandidate]) async throws -> [UUID: ReminderDeliveryState] {
        let remindersWithDates = reminders.filter { $0.dueAt != nil }
        guard !remindersWithDates.isEmpty else { return [:] }

        let center = try notificationCenter()
        let pendingIdentifiers = Set(await center.pendingNotificationRequests().map(\.identifier))
        let deliveredIdentifiers = Set(await center.deliveredNotifications().map { $0.request.identifier })

        return Dictionary(uniqueKeysWithValues: remindersWithDates.map { reminder in
            let identifier = reminder.id.uuidString
            let status: ReminderDeliveryState
            if deliveredIdentifiers.contains(identifier) {
                status = .delivered
            } else if pendingIdentifiers.contains(identifier) {
                status = .pending
            } else {
                status = .notFound
            }
            return (reminder.id, status)
        })
    }

    public func scheduleDailyReview(hour: Int = 18, minute: Int = 0) async throws {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ReminderNotificationError.authorizationRequired
        }
        let content = UNMutableNotificationContent()
        content.title = "Recall 每日回顾"
        content.body = "查看今天已显式记录的工作节点与待确认事项。"
        content.sound = .default
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let request = UNNotificationRequest(
            identifier: "im.recall.app.daily-review",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        do {
            try await center.add(request)
        } catch {
            throw notificationError(from: error)
        }
    }

    public func deliverDailyBriefing(_ summary: DailySummary) async throws {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ReminderNotificationError.authorizationRequired
        }
        let content = UNMutableNotificationContent()
        content.title = "Recall 已生成个人简报"
        content.body = summary.briefing?.headline ?? "昨天的关键进展、未闭环事项和个性化建议已整理完成。"
        content.sound = .default
        content.userInfo = ["dailySummaryID": summary.id.uuidString]
        let identifier = "im.recall.app.daily-summary.\(Int(summary.day.timeIntervalSince1970))"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        do {
            try await center.add(request)
        } catch {
            throw notificationError(from: error)
        }
    }

    public func cancelDailyReview() {
        guard isNotificationHostAvailable else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["im.recall.app.daily-review"])
    }

    public func cancel(_ reminder: ReminderCandidate) {
        guard isNotificationHostAvailable else { return }
        let identifiers = [reminder.id.uuidString]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private var isNotificationHostAvailable: Bool {
        let mainBundle = Bundle.main
        return mainBundle.bundleURL.pathExtension.lowercased() == "app"
            && !(mainBundle.bundleIdentifier?.isEmpty ?? true)
    }

    private func notificationCenter() throws -> UNUserNotificationCenter {
        guard isNotificationHostAvailable else {
            throw ReminderNotificationError.hostApplicationRequired
        }
        return UNUserNotificationCenter.current()
    }

    private func notificationError(from error: Error) -> ReminderNotificationError {
        let systemError = error as NSError
        if systemError.domain == "UNErrorDomain" && systemError.code == 1 {
            return .notificationNotPermitted
        }
        return .notificationSchedulingFailed
    }
}

public enum ReminderDeliveryState: String, Sendable, Hashable {
    /// 通知请求已被 macOS 接受，等待达到用户确认的时间。
    case pending
    /// macOS 已将通知交付给通知中心；用户是否已阅读由系统负责。
    case delivered
    /// 本地记录显示已安排，但系统队列中没有对应请求或已投递通知。
    case notFound
}

public enum ReminderNotificationError: LocalizedError {
    case authorizationRequired
    case missingDueDate
    case hostApplicationRequired
    case notificationNotPermitted
    case notificationSchedulingFailed

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: "请先允许应用发送提醒通知。"
        case .missingDueDate: "请为提醒选择一个时间。"
        case .hostApplicationRequired: "提醒通知需要从 Recall.app 启动；当前调试可执行文件无法安全请求系统通知。"
        case .notificationNotPermitted: "macOS 拒绝了此提醒请求。请退出并重新通过 Recall.app 启动，然后在系统设置 → 通知 → Recall 中允许通知。"
        case .notificationSchedulingFailed: "提醒未能安排。请检查系统设置 → 通知 → Recall 的授权状态后重试。"
        }
    }
}
