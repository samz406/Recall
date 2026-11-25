import Foundation

/// 主题列表的纯展示逻辑：分组与相对时间。不读写存档，便于验证。
public enum TopicListPresentation {
    /// 进行中：最近事件仍未完成且在 14 天内有动静；其余（已完成、搁置）折叠。
    public static func group(_ files: [MatterFile], now: Date = .now,
                             calendar: Calendar = .current) -> (active: [MatterFile], done: [MatterFile]) {
        var active: [MatterFile] = [], done: [MatterFile] = []
        for file in files {
            if file.latest.status.isOpenMatter && !file.needsStatusUpdate(at: now, calendar: calendar) {
                active.append(file)
            } else {
                done.append(file)
            }
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
