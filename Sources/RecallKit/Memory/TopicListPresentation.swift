import Foundation

/// 主题列表的纯展示逻辑：分组与相对时间。不读写存档，便于验证。
public enum TopicListPresentation {
    /// 进行中：生命周期为 active 的主题；已完成、搁置（14 天没有动静）与归档折叠。
    /// 没有登记表时退回按最近事件状态判断。
    public static func group(_ files: [MatterFile], now: Date = .now, calendar: Calendar = .current,
                             registry: TopicRegistry = TopicRegistry()) -> (active: [MatterFile], done: [MatterFile]) {
        var active: [MatterFile] = [], done: [MatterFile] = []
        for file in files {
            let lifecycle = registry.topics.isEmpty
                ? (file.latest.status.isOpenMatter && !file.needsStatusUpdate(at: now, calendar: calendar) ? Topic.Lifecycle.active : .done)
                : TopicRegistry.lifecycle(for: file, topic: registry.topic(forName: file.title), now: now, calendar: calendar)
            if lifecycle == .active { active.append(file) } else { done.append(file) }
        }
        return (active, done)
    }

    public static func relativeTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return RecallLocalization.both("今天", "Today")
        case 1: return RecallLocalization.both("昨天", "Yesterday")
        case 2...30: return RecallLocalization.both("\(days) 天前", "\(days) days ago")
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}
