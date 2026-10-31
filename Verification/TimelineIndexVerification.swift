import Foundation
import RecallKit

enum TimelineIndexVerification {
    static func run() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        func record(_ date: Date, _ app: String, _ text: String) -> CaptureRecord {
            CaptureRecord(eventTemplate: .manualMoment, createdAt: date, sourceAppName: app,
                          sourceBundleIdentifier: "example." + app, contentHash: UUID().uuidString, ocrText: text)
        }
        let a = record(day.addingTimeInterval(60), "Chat", "Atlas 验收"),
            duplicate = record(day.addingTimeInterval(120), "Chat", "Atlas 验收"),
            b = record(next.addingTimeInterval(-1), "Browser", "Nova 方案"),
            c = record(next, "Chat", "Atlas 后续")
        let index = try TimelineIndex(captures: [b, c, a, duplicate], calendar: calendar)
        var query = TimelineQuery(day: day)
        let first = try index.result(for: query)
        try expect(first.captures.map(\.id) == [b.id, duplicate.id, a.id], "日期索引未遵守夏令时的 25 小时自然日边界")
        try expect(index.maximumDayCount == 3 && index.days.map(\.count) == [1, 3], "日期统计或强度条数据错误")
        try expect(first.clusterCount == 2 && first.hours.flatMap(\.clusters).last?.records.count == 2, "浏览重复记录没有按原规则合并")
        query.collapseDuplicates = false
        try expect(try index.result(for: query).clusterCount == 3, "管理模式丢失原始记录")
        query.searchText = "Atlas"; query.source = "Chat"
        try expect(try index.result(for: query).captures.count == 2, "当天搜索越过日期或来源边界")
        query.searchAllDates = true
        try expect(try index.result(for: query).captures.count == 3, "全部日期搜索遗漏历史内容")
        query.searchText = ""; query.day = next
        try expect(try index.result(for: query).captures.map(\.id) == [c.id], "无关键词时错误展示全部日期")
        let replaced = try TimelineIndex(captures: [c], calendar: calendar)
        try expect(try replaced.result(for: TimelineQuery(day: day)).captures.isEmpty, "删除后新索引仍包含旧记录")
        var shifted = calendar; shifted.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcIndex = try TimelineIndex(captures: [a, duplicate, b, c], calendar: shifted)
        try expect(utcIndex.days.map(\.count) != index.days.map(\.count), "时区改变没有重新划分日期")
        print("PASS: 4 timeline-index scenarios (DST boundaries, exact duplicates, scoped search and source/timezone replacement)")
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw VerificationError.failed(message) }
    }
}
