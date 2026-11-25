import Foundation
import RecallKit

/// 主题列表的摘要与分组：摘要取最近一件具体事情，完成与搁置折叠。
enum TopicListVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }

    static func run() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!
        func file(_ id: String, daysAgo: Int, status: WorkEpisodeStatus, headline: String?) -> MatterFile {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            var event = MatterEvent(id: UUID(), title: id, detail: "PR #123 修复 env=FOO 表 t_order 细节",
                recordedAt: day, eventAt: day, status: status, evidenceIDs: [UUID()], nextAction: nil)
            event.headline = headline
            return MatterFile(id: id, title: id, events: [event])
        }

        let withHeadline = TopicReading(file: file("topic:a", daysAgo: 1, status: .progressed,
            headline: "历史气泡误挂思考中表情的问题已定位并修复"))
        try expect(withHeadline.headline == "历史气泡误挂思考中表情的问题已定位并修复",
                   "摘要应使用最近事件的 headline，而不是带执行细节的 detail")

        let withoutHeadline = TopicReading(file: file("topic:b", daysAgo: 1, status: .progressed, headline: nil))
        try expect(withoutHeadline.headline.count <= 60, "没有 headline 时应回退为截断的 detail")
        try expect(!withoutHeadline.headline.isEmpty, "回退摘要不能为空")

        let groups = TopicListPresentation.group([
            file("topic:a", daysAgo: 1, status: .progressed, headline: nil),
            file("topic:b", daysAgo: 2, status: .completed, headline: nil),
            file("topic:c", daysAgo: 30, status: .progressed, headline: nil)
        ], now: now, calendar: calendar)
        try expect(groups.active.map(\.id) == ["topic:a"], "进行中只含近期仍未完成的事项")
        try expect(Set(groups.done.map(\.id)) == ["topic:b", "topic:c"], "已完成与超过 14 天没有动静的归入折叠组")

        try expect(TopicListPresentation.relativeTime(now, now: now, calendar: calendar) == "今天", "相对时间：今天")
        try expect(TopicListPresentation.relativeTime(calendar.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: calendar) == "昨天", "相对时间：昨天")
        try expect(TopicListPresentation.relativeTime(calendar.date(byAdding: .day, value: -3, to: now)!, now: now, calendar: calendar) == "3 天前", "相对时间：N 天前")

        print("PASS: topic list presentation (headline fallback, status grouping, relative time)")
    }
}
