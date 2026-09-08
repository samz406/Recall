import Foundation
import UserNotifications

public struct ReminderExtractor: Sendable {
    public init() {}

    public func candidates(from captures: [CaptureRecord], existing: [ReminderCandidate]) -> [ReminderCandidate] {
        let existingTitles = existing.map(\.title)
        var result: [ReminderCandidate] = []

        for capture in captures.sorted(by: { $0.createdAt > $1.createdAt }) where !capture.ocrText.isEmpty {
            for segment in segments(from: capture.ocrText) {
                guard let analysis = analyze(segment, base: capture.createdAt) else { continue }
                guard !existingTitles.contains(where: { isSemanticallyEquivalent($0, analysis.title) }) else { continue }

                if let index = result.firstIndex(where: { isSemanticallyEquivalent($0.title, analysis.title) }) {
                    if !result[index].sourceCaptureIDs.contains(capture.id) {
                        result[index].sourceCaptureIDs.append(capture.id)
                    }
                    result[index].confidence = max(result[index].confidence, analysis.confidence)
                    if result[index].dueAt == nil {
                        result[index].dueAt = analysis.dueAt
                    }
                    continue
                }

                let source = capture.sourceAppName ?? "本地记录"
                let timeNote = analysis.dueAt == nil ? "未发现明确时间" : "已识别时间线索"
                result.append(
                    ReminderCandidate(
                        title: analysis.title,
                        detail: "来自 \(source)；\(timeNote)，请核对来源后再安排。",
                        dueAt: analysis.dueAt,
                        sourceCaptureIDs: [capture.id],
                        confidence: analysis.confidence
                    )
                )
            }
        }
        return result
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture)
            }
            .prefix(200)
            .map { $0 }
    }

    private struct Analysis {
        let title: String
        let dueAt: Date?
        let confidence: Double
    }

    private func analyze(_ rawText: String, base: Date) -> Analysis? {
        let compact = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = compact.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard compact.count >= 5, compact.count <= 300 else { return nil }
        guard !looksLikeNoise(lower), !looksLikeQuestion(compact), !looksCompleted(lower) else { return nil }

        let explicitMarkers = ["待办", "任务", "todo", "action item", "记得", "别忘", "务必", "提醒我"]
        let directiveMarkers = ["需要", "应该", "应当", "必须", "请", "计划", "准备", "要在", "需在", "下一步"]
        let actionVerbs = [
            "回复", "提交", "完成", "跟进", "处理", "联系", "确认", "预约", "支付", "续费",
            "更新", "发送", "整理", "准备", "参加", "取消", "购买", "缴纳", "检查", "修复",
            "发布", "交付", "申请", "撰写", "写一", "follow up", "send", "submit", "finish",
            "call", "email", "pay", "renew", "schedule"
        ]
        let timeMarkers = [
            "今天", "明天", "后天", "本周", "这周", "下周", "周一", "周二", "周三", "周四",
            "周五", "周六", "周日", "星期", "月底", "月末", "日前", "之前", "截止", "到期",
            "today", "tomorrow", "next week", "deadline", "due"
        ]

        let hasExplicitMarker = explicitMarkers.contains(where: { lower.contains($0) })
        let hasDirective = directiveMarkers.contains(where: { lower.contains($0) })
        let matchedActionVerb = actionVerbs.first(where: { lower.contains($0) })
        let hasAction = matchedActionVerb != nil
        let hasTime = timeMarkers.contains(where: { lower.contains($0) }) || containsExplicitDate(lower)
        let title = normalizedTitle(from: compact, actionVerbs: actionVerbs)
        let startsWithAction = actionVerbs.contains { title.localizedCaseInsensitiveContains($0) && title.lowercased().hasPrefix($0.lowercased()) }

        guard hasAction, hasExplicitMarker || hasDirective || hasTime || startsWithAction else { return nil }
        guard title.count >= 5 else { return nil }

        let dueAt = inferredDueDate(in: compact, base: base)
        var confidence = 0.18
        if hasExplicitMarker { confidence += 0.34 }
        if hasDirective { confidence += 0.20 }
        if hasAction { confidence += 0.24 }
        if startsWithAction { confidence += 0.10 }
        if hasTime { confidence += 0.10 }
        if dueAt != nil { confidence += 0.06 }
        if lower.contains("截止") || lower.contains("deadline") || lower.contains("due") { confidence += 0.06 }
        confidence = min(confidence, 0.96)
        guard confidence >= 0.60 else { return nil }
        return Analysis(title: title, dueAt: dueAt, confidence: confidence)
    }

    private func segments(from text: String) -> [String] {
        text.split { character in
            character.isNewline || "。！？!?；;".contains(character)
        }
        .map(String.init)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    private func looksLikeNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let noisePrefixes = ["//", "/*", "#!", "$ ", "> ", "select ", "insert ", "update ", "delete "]
        let noisePhrases = ["test log", "debug log", "lorem ipsum", "console.log", "system.out", "测试日志"]
        return noisePrefixes.contains(where: { trimmed.hasPrefix($0) })
            || noisePhrases.contains(where: { trimmed.contains($0) })
            || trimmed.range(of: #"^[/\\]{1,2}(todo|fixme)\b"#, options: .regularExpression) != nil
    }

    private func looksLikeQuestion(_ text: String) -> Bool {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uncertaintyMarkers = ["是不是", "是否", "能否", "要不要", "可不可以", "可能", "好像", "我记得"]
        let questionEndings = ["吗", "呢", "吧", "么", "？", "?"]
        return questionEndings.contains(where: { compact.hasSuffix($0) })
            || (uncertaintyMarkers.contains(where: { compact.contains($0) }) && !compact.contains("提醒我"))
    }

    private func looksCompleted(_ text: String) -> Bool {
        if ["未完成", "尚未完成", "还没完成", "没有完成"].contains(where: { text.contains($0) }) { return false }
        let completedMarkers = [
            "已完成", "已经完成", "完成了", "已提交", "已经提交", "已回复", "已经回复",
            "已处理", "已经处理", "已解决", "搞定了", "done", "completed", "finished"
        ]
        return completedMarkers.contains(where: { text.contains($0) })
    }

    private func normalizedTitle(from source: String, actionVerbs: [String]) -> String {
        var title = source
            .replacingOccurrences(of: #"^[\s•·●\-*]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)^(待办|todo|action item|任务|下一步)\s*[:：\-]\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for separator in ["，", ","] {
            guard let index = title.firstIndex(of: Character(separator)) else { continue }
            let leadingClause = String(title[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if leadingClause.count >= 5, actionVerbs.contains(where: { leadingClause.localizedCaseInsensitiveContains($0) }) {
                title = leadingClause
                break
            }
        }
        return String(title.prefix(96)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSemanticallyEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = fingerprint(lhs)
        let right = fingerprint(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        if min(left.count, right.count) >= 8 && (left.contains(right) || right.contains(left)) { return true }

        let leftPairs = characterPairs(in: left)
        let rightPairs = characterPairs(in: right)
        guard !leftPairs.isEmpty, !rightPairs.isEmpty else { return false }
        let intersection = leftPairs.intersection(rightPairs).count
        let union = leftPairs.union(rightPairs).count
        return union > 0 && Double(intersection) / Double(union) >= 0.72
    }

    private func fingerprint(_ source: String) -> String {
        let folded = source.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let taskMarkers = ["待办", "todo", "actionitem", "任务", "记得", "请", "需要", "务必"]
        var compact = String(folded.filter { $0.isLetter || $0.isNumber })
        for marker in taskMarkers {
            compact = compact.replacingOccurrences(of: marker, with: "")
        }
        return compact
    }

    private func characterPairs(in source: String) -> Set<String> {
        let characters = Array(source)
        guard characters.count >= 2 else { return Set(characters.map(String.init)) }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }

    private func containsExplicitDate(_ text: String) -> Bool {
        text.range(of: #"\d{1,4}[-/.年]\d{1,2}(?:[-/.月]\d{1,2})?"#, options: .regularExpression) != nil
            || text.range(of: #"\d{1,2}月\d{1,2}[日号]?"#, options: .regularExpression) != nil
    }

    private func inferredDueDate(in text: String, base: Date) -> Date? {
        let calendar = Calendar.current
        let time = inferredTime(in: text)
        if let exactDate = inferredExplicitDate(in: text, base: base, calendar: calendar) {
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: exactDate)
        }

        let lower = text.lowercased()
        let dayOffset: Int?
        if text.contains("后天") {
            dayOffset = 2
        } else if text.contains("明天") || lower.contains("tomorrow") {
            dayOffset = 1
        } else if text.contains("今天") || lower.contains("today") {
            dayOffset = 0
        } else if let weekdayDate = inferredWeekday(in: text, base: base, calendar: calendar) {
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: weekdayDate)
        } else if text.contains("下周") || lower.contains("next week") {
            dayOffset = 7
        } else {
            dayOffset = nil
        }

        if let dayOffset,
           let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: base)) {
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: targetDay)
        }
        return nil
    }

    private func inferredTime(in text: String) -> (hour: Int, minute: Int) {
        if let parts = firstMatch(#"(?<!\d)(\d{1,2})(?:[:：点时])(\d{1,2})?"#, in: text),
           let rawHour = Int(parts[1]) {
            var hour = min(max(rawHour, 0), 23)
            let minute = parts.count > 2 ? min(max(Int(parts[2]) ?? 0, 0), 59) : 0
            if (text.contains("下午") || text.contains("晚上")) && hour < 12 { hour += 12 }
            if text.contains("中午") && hour < 11 { hour += 12 }
            return (hour, minute)
        }
        if text.contains("早上") || text.contains("上午") { return (9, 0) }
        if text.contains("中午") { return (12, 0) }
        if text.contains("下午") { return (15, 0) }
        if text.contains("晚上") || text.contains("今晚") { return (20, 0) }
        return (9, 0)
    }

    private func inferredExplicitDate(in text: String, base: Date, calendar: Calendar) -> Date? {
        if let parts = firstMatch(#"(?<!\d)(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})[日号]?"#, in: text),
           let year = Int(parts[1]), let month = Int(parts[2]), let day = Int(parts[3]) {
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        if let parts = firstMatch(#"(?<!\d)(\d{1,2})月(\d{1,2})[日号]?"#, in: text),
           let month = Int(parts[1]), let day = Int(parts[2]) {
            let baseYear = calendar.component(.year, from: base)
            let candidate = calendar.date(from: DateComponents(year: baseYear, month: month, day: day))
            if let candidate, candidate < calendar.startOfDay(for: base) {
                return calendar.date(from: DateComponents(year: baseYear + 1, month: month, day: day))
            }
            return candidate
        }
        if let parts = firstMatch(#"(?<!\d)(\d{1,2})[/-](\d{1,2})(?!\d)"#, in: text),
           let month = Int(parts[1]), let day = Int(parts[2]) {
            let baseYear = calendar.component(.year, from: base)
            let candidate = calendar.date(from: DateComponents(year: baseYear, month: month, day: day))
            if let candidate, candidate < calendar.startOfDay(for: base) {
                return calendar.date(from: DateComponents(year: baseYear + 1, month: month, day: day))
            }
            return candidate
        }
        return nil
    }

    private func inferredWeekday(in text: String, base: Date, calendar: Calendar) -> Date? {
        guard let parts = firstMatch(#"((?:下|本|这)?(?:周|星期))([一二三四五六日天])"#, in: text) else { return nil }
        let targetWeekday: Int
        switch parts[2] {
        case "一": targetWeekday = 2
        case "二": targetWeekday = 3
        case "三": targetWeekday = 4
        case "四": targetWeekday = 5
        case "五": targetWeekday = 6
        case "六": targetWeekday = 7
        default: targetWeekday = 1
        }
        let baseDay = calendar.startOfDay(for: base)
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: baseDay)?.start else { return nil }
        let weekStartWeekday = calendar.component(.weekday, from: weekStart)
        let offsetWithinWeek = (targetWeekday - weekStartWeekday + 7) % 7
        let weekOffset = parts[1].contains("下") ? 7 : 0
        guard let candidate = calendar.date(byAdding: .day, value: weekOffset + offsetWithinWeek, to: weekStart) else { return nil }
        if candidate < baseDay && !parts[1].contains("本") && !parts[1].contains("这") {
            return calendar.date(byAdding: .day, value: 7, to: candidate)
        }
        return candidate
    }

    private func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
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
