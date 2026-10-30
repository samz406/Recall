import Foundation
import CryptoKit

public extension ReminderStatus {
    var isHistory: Bool { self == .completed || self == .dismissed || self == .cancelled }
}

public struct ReminderSourceChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
    public init?(capture: CaptureRecord) {
        let name = capture.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundle = capture.sourceBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bundle.isEmpty || !name.isEmpty else { return nil }
        id = bundle.isEmpty ? Self.nameKey(name) : "bundle:" + bundle.lowercased()
        title = name.isEmpty ? bundle : name
    }
    public var isApplication: Bool { id.hasPrefix("bundle:") || id.hasPrefix("name:") }
    static func nameKey(_ name: String) -> String { "name:" + name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
}

/// Only a fingerprint and provenance remain after clearing history; no reminder text is retained.
public struct ReminderHistorySuppression: Codable, Hashable, Sendable {
    public var fingerprint: String
    public var sourceIDs: Set<UUID>
    public var dueAt: Date?
    public var expiresAt: Date
    public init(reminder: ReminderCandidate) {
        fingerprint = Self.digest(reminder.title)
        sourceIDs = Set(reminder.sourceCaptureIDs); dueAt = reminder.dueAt
        let closed = reminder.closedAt ?? reminder.completedAt ?? reminder.updatedAt
        expiresAt = reminder.status == .dismissed
            ? (reminder.dismissedUntil ?? closed.addingTimeInterval(30 * 86_400))
            : closed.addingTimeInterval((reminder.dueAt == nil ? 7.0 : 180.0) * 86_400)
    }
    public func matches(_ candidate: ReminderCandidate, now: Date) -> Bool {
        guard expiresAt > now, fingerprint == Self.digest(candidate.title) else { return false }
        if let dueAt, let newDate = candidate.dueAt { return Calendar.current.isDate(dueAt, inSameDayAs: newDate) }
        return true
    }
    static func digest(_ title: String) -> String {
        let compact = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).filter { $0.isLetter || $0.isNumber }
        return SHA256.hash(data: Data(compact.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public extension ReminderLearningProfile {
    var disabledReminderApplications: [String: String] { excludedApplications ?? [:] }
    func permitsReminderDiscovery(from capture: CaptureRecord) -> Bool {
        guard let source = ReminderSourceChoice(capture: capture) else { return true }
        let blocked = disabledReminderApplications
        if blocked[source.id] != nil { return false }
        if let name = capture.sourceAppName, blocked[ReminderSourceChoice.nameKey(name)] != nil { return false }
        return true
    }
    func suppressesHistory(_ candidate: ReminderCandidate, now: Date = .now) -> Bool {
        (clearedHistory ?? []).contains { $0.matches(candidate, now: now) }
    }
    mutating func retainHistorySuppression(_ reminders: [ReminderCandidate], now: Date) {
        var retained = (clearedHistory ?? []).filter { $0.expiresAt > now }
        for reminder in reminders where reminder.origin != .manual {
            let mark = ReminderHistorySuppression(reminder: reminder)
            guard mark.expiresAt > now else { continue }
            retained.removeAll { $0.fingerprint == mark.fingerprint && $0.dueAt == mark.dueAt }
            retained.append(mark)
        }
        clearedHistory = Array(retained.sorted { $0.expiresAt > $1.expiresAt }.prefix(1_000))
    }
    mutating func removeHistorySources(_ ids: Set<UUID>) {
        clearedHistory?.removeAll { !$0.sourceIDs.isDisjoint(with: ids) }
    }
}

public enum ReminderHistoryFilter: Int, CaseIterable, Identifiable, Sendable {
    case all, completed, dismissedAndCancelled
    public var id: Int { rawValue }
    public var title: String {
        switch self { case .all: "全部"; case .completed: "已完成"; case .dismissedAndCancelled: "已忽略与取消" }
    }
    public func includes(_ status: ReminderStatus) -> Bool {
        status.isHistory && (self == .all || (self == .completed ? status == .completed : status != .completed))
    }
}

public struct ReminderHistoryRow: Identifiable, Sendable {
    public let id: String
    public let day: Date
    public var reminders: [ReminderCandidate]
    public let title: String
    public let sources: [ReminderSourceChoice]
    public var latest: ReminderCandidate { reminders[0] }
    public var date: Date { Self.date(of: latest) }
    public var sourceIDs: Set<UUID> { Set(reminders.flatMap(\.sourceCaptureIDs)) }
    public var reminderIDs: Set<UUID> { Set(reminders.map(\.id)) }
    public var sourceDescription: String { sources.map(\.title).joined(separator: "、") }
    public var sourceReminder: ReminderCandidate {
        var result = latest; result.title = title; result.sourceCaptureIDs = sourceIDs.sorted { $0.uuidString < $1.uuidString }; return result
    }
    public static func date(of reminder: ReminderCandidate) -> Date { reminder.closedAt ?? (reminder.status == .completed ? reminder.completedAt : nil) ?? reminder.updatedAt }
}

public struct ReminderHistoryDay: Identifiable, Sendable {
    public let day: Date
    public let rows: [ReminderHistoryRow]
    public var id: Date { day }
    public var recordCount: Int { rows.reduce(0) { $0 + $1.reminders.count } }
    public func title(now: Date = .now, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let date = "\(parts.month ?? 1)月\(parts.day ?? 1)日"
        if calendar.isDate(day, inSameDayAs: now) { return "今天 · " + date }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "昨天 · " + date }
        return calendar.component(.year, from: now) == parts.year ? date : "\(parts.year ?? 0)年" + date
    }
}

/// Search and source/status filtering precede grouping and pagination, so counts and actions agree.
public struct ReminderHistoryIndex: Sendable {
    public let reminders: [ReminderCandidate]
    private let captures: [UUID: CaptureRecord]
    public init(reminders: [ReminderCandidate], captures: [CaptureRecord]) {
        self.reminders = reminders.filter { $0.status.isHistory }
        self.captures = Dictionary(captures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    public func sources(for reminder: ReminderCandidate) -> [ReminderSourceChoice] {
        if reminder.origin == .manual { return [ReminderSourceChoice(id: "manual", title: "手动创建")] }
        let captured = reminder.sourceCaptureIDs.compactMap { captures[$0] }.sorted { $0.createdAt > $1.createdAt }
        let sources = Dictionary(captured.compactMap(ReminderSourceChoice.init(capture:)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sources.isEmpty ? [ReminderSourceChoice(id: "unavailable", title: "来源未保留")] : sources.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public var sourceChoices: [ReminderSourceChoice] {
        let all = reminders.sorted { $0.updatedAt > $1.updatedAt }.flatMap(sources(for:))
        return Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public func matching(search: String = "", sourceID: String? = nil) -> [ReminderCandidate] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return reminders.filter { reminder in
            let sources = sources(for: reminder)
            guard sourceID == nil || sources.contains(where: { $0.id == sourceID }) else { return false }
            let haystack = reminder.title + " " + reminder.detail + " " + sources.map(\.title).joined(separator: " ")
            return terms.allSatisfy { haystack.localizedStandardContains($0) }
        }
    }
    public func rows(filter: ReminderHistoryFilter = .all, search: String = "", sourceID: String? = nil, calendar: Calendar = .current) -> [ReminderHistoryRow] {
        var rows: [String: ReminderHistoryRow] = [:]
        for reminder in matching(search: search, sourceID: sourceID).filter({ filter.includes($0.status) }).sorted(by: {
            let left = ReminderHistoryRow.date(of: $0), right = ReminderHistoryRow.date(of: $1)
            return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
        }) {
            let title = Self.displayTitle(reminder.title)
            let sources = sources(for: reminder)
            let day = calendar.startOfDay(for: ReminderHistoryRow.date(of: reminder))
            // Never merge another day's result, a different status or an unrelated source application.
            let key = "\(day.timeIntervalSince1970)|\(reminder.status.rawValue)|\(sources.map(\.id).sorted().joined(separator: ","))|\(title)"
            if rows[key] != nil { rows[key]!.reminders.append(reminder) }
            else { rows[key] = ReminderHistoryRow(id: key, day: day, reminders: [reminder], title: title, sources: sources) }
        }
        return rows.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    public static func days(for rows: [ReminderHistoryRow]) -> [ReminderHistoryDay] {
        Dictionary(grouping: rows, by: \.day).map { ReminderHistoryDay(day: $0.key, rows: $0.value) }.sorted { $0.day > $1.day }
    }
    public static func displayTitle(_ title: String) -> String {
        let clean = title.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"^\s*(?:[-*•]\s+|\d+[.)、]\s*)"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? "未命名提醒" : clean
    }
}
