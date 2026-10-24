import Foundation

/// User-directed presentation grouping. Original facts, dates and sources are never rewritten.
public struct MemoryTopicGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var memberIDs: [String]
    public var sourceIDs: [UUID]? = nil
    public var createdAt: Date
    public init(title: String, memberIDs: [String]) {
        id = "group:" + UUID().uuidString; self.title = title
        self.memberIDs = Array(Set(memberIDs)).sorted(); createdAt = .now
    }
    public static func applying(_ groups: [Self], to files: [MatterFile]) -> [MatterFile] {
        var result = files
        for group in groups {
            let members = result.filter { group.memberIDs.contains($0.id) }
            guard !members.isEmpty else { continue }
            var seen: Set<UUID> = []
            let events = members.flatMap(\.events).sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                return $0.sequence == $1.sequence ? $0.id.uuidString < $1.id.uuidString : $0.sequence < $1.sequence
            }.filter { seen.insert($0.id).inserted }
            result.removeAll { group.memberIDs.contains($0.id) }
            result.append(MatterFile(id: group.id, title: group.title, events: events))
        }
        return result.sorted { $0.latest.date == $1.latest.date ? $0.id < $1.id : $0.latest.date > $1.latest.date }
    }
}

public enum ReviewContentQuality {
    public static func titleAndDetail(_ text: String) -> [String] {
        var depth = 0
        for index in text.indices {
            let c = text[index]
            if "（([《\"".contains(c) { depth += 1 }
            if "）)]》".contains(c) { depth = max(0, depth - 1) }
            guard depth == 0, c == ":" || c == "：" else { continue }
            let before = String(text[..<index]), after = String(text[text.index(after: index)...])
            if c == ":", (before.last?.isNumber == true && after.first?.isNumber == true || after.hasPrefix("//")) { continue }
            guard !before.contains("http"), !before.contains("/"), before.range(of: #"\.[A-Za-z]{1,8}(?:\s|$)"#, options: .regularExpression) == nil, before.count <= 36,
                  !after.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            return [before, after]
        }
        return [text]
    }
    public static func usefulInsight(title: String, detail: String) -> Bool {
        let text = title + "；" + detail
        let unsupported = ["高度同构", "心理熵", "上下文切换偏多", "主线尚未成型", "工作片段", "记录密度", "截图数量",
                           "流水线已经稳定", "流水线已稳定", "流程已经成熟", "固定工艺", "人格", "性格特征"]
        if unsupported.contains(where: text.contains) { return false }
        if ["多次打开", "反复打开", "高频切换"].contains(where: text.contains)
            && ["偏好", "心理", "焦虑", "负担", "习惯"].contains(where: text.contains) { return false }
        return !(text.contains("没有新") && ["停滞", "未推进", "拖延"].contains(where: text.contains))
    }
    /// Complete sentences only. A length budget is never a reason to cut words in half.
    public static func shortDetail(_ text: String) -> String {
        let pieces = text.components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return pieces.first.map { $0 + (pieces.count > 1 ? "。" : "") } ?? text
    }
    public static func presentation(_ item: DailySummaryItem) -> (title: String, detail: String) {
        guard let safe = DailySummaryItemParser.sanitized([item]).first else { return ("", "") }
        return (safe.title, safe.detail)
    }
}

public struct TimelineRecordCluster: Identifiable, Sendable {
    public var id: UUID { records[0].id }
    public var records: [CaptureRecord]
    public static func make(_ records: [CaptureRecord], enabled: Bool) -> [Self] {
        var groups: [Self] = []
        for record in records {
            if enabled, let last = groups.last?.records.last,
               last.sourceBundleIdentifier == record.sourceBundleIdentifier,
               !record.ocrText.isEmpty, last.ocrText == record.ocrText,
               abs(last.createdAt.timeIntervalSince(record.createdAt)) <= 180 {
                groups[groups.count - 1].records.append(record)
            } else { groups.append(Self(records: [record])) }
        }
        return groups
    }
}

public enum MemorySearchDestination: Hashable, Sendable {
    case record(UUID), topic(String), daily(UUID), review(UUID), reminder(UUID), knowledge(UUID)
}
public struct MemorySearchHit: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var kind: String
    public var date: Date
    public var sourceIDs: Set<UUID>
    public var destination: MemorySearchDestination
}
public struct GlobalMemorySearch: Sendable {
    private var rows: [MemorySearchHit]
    private var apps: [UUID: String]
    public init(state: RecallState, matters: [MatterFile]) {
        let excluded = state.privacy.excludedBundleIdentifiers
        let sources = state.captures.filter { !excluded.contains($0.sourceBundleIdentifier ?? "") }
        let ids = Set(sources.map(\.id))
        apps = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.sourceAppName ?? "") })
        var hits: [MemorySearchHit] = sources.map {
            MemorySearchHit(id: "record:" + $0.id.uuidString, title: CapturePresentation(capture: $0).title,
                detail: $0.ocrText, kind: "原始记录", date: $0.createdAt, sourceIDs: [$0.id], destination: .record($0.id))
        }
        for file in matters where Set(file.evidenceIDs).isSubset(of: ids) {
            hits.append(.init(id: "topic:" + file.id, title: file.title, detail: file.events.map(\.detail).joined(separator: "\n"), kind: "记忆主题",
                date: file.latest.date, sourceIDs: Set(file.evidenceIDs), destination: .topic(file.id)))
        }
        for report in state.dailySummaries where Set(report.sourceCaptureIDs).isSubset(of: ids) {
            hits.append(.init(id: "daily:" + report.id.uuidString, title: report.day.formatted(date: .abbreviated, time: .omitted) + " · 每日回顾",
                detail: DailySummaryItemParser.markdown(from: report.items), kind: "每日回顾", date: report.day,
                sourceIDs: Set(report.sourceCaptureIDs), destination: .daily(report.id)))
        }
        for report in state.weeklyReports where report.isReadable && report.sourceIDs.isSubset(of: ids) {
            hits.append(.init(id: "review:" + report.id.uuidString, title: report.template.name, detail: report.markdown,
                kind: "周期回顾", date: report.createdAt, sourceIDs: report.sourceIDs, destination: .review(report.id)))
        }
        for reminder in state.reminders where Set(reminder.sourceCaptureIDs).isSubset(of: ids) {
            hits.append(.init(id: "reminder:" + reminder.id.uuidString, title: reminder.title, detail: reminder.detail, kind: "提醒",
                date: reminder.updatedAt, sourceIDs: Set(reminder.sourceCaptureIDs), destination: .reminder(reminder.id)))
        }
        for claim in state.memoryKnowledge.claims where claim.usable(at: .now) && claim.scope != .conversation && Set(claim.sourceIDs).isSubset(of: ids) {
            hits.append(.init(id: "knowledge:" + claim.id.uuidString, title: claim.title, detail: claim.content, kind: "长期记忆",
                date: claim.date, sourceIDs: Set(claim.sourceIDs), destination: .knowledge(claim.id)))
        }
        rows = hits
    }
    public func search(_ text: String, start: Date? = nil, end: Date? = nil, app: String? = nil, limit: Int = 50) -> [MemorySearchHit] {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        return rows.filter { row in
            (start == nil || row.date >= start!) && (end == nil || row.date < end!)
                && (app == nil || row.sourceIDs.contains { apps[$0] == app })
                && terms.allSatisfy { (row.title + " " + row.detail).localizedCaseInsensitiveContains($0) }
        }.sorted {
            let a = $0.title.localizedCaseInsensitiveContains(text), b = $1.title.localizedCaseInsensitiveContains(text)
            return a == b ? ($0.date == $1.date ? $0.id < $1.id : $0.date > $1.date) : a
        }.prefix(max(1, limit)).map { $0 }
    }
}

public enum RecallTaskState: String, Sendable { case running, succeeded, partial, failed, cancelled }
public struct DailyReviewVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var items: [DailySummaryItem]
    public var sourceIDs: [UUID]
    public init(summary: DailySummary) {
        id = summary.id; createdAt = summary.createdAt; items = summary.items; sourceIDs = summary.sourceCaptureIDs
    }
}
public struct RecallTaskStatus: Identifiable, Sendable {
    public var id = UUID()
    public var kind: String
    public var target: String
    public var phase: String
    public var state: RecallTaskState = .running
    public var startedAt = Date.now
    public var destination: MemorySearchDestination?
    public var isRunning: Bool { state == .running }
    public init(kind: String, target: String, phase: String) { self.kind = kind; self.target = target; self.phase = phase }
}
