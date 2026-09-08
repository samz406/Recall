import Foundation

/// 基于用户设备当前日历和时区，将记录归入本地自然日。
/// 该逻辑只处理已有的创建时间，不读取 OCR 正文，也不发送任何数据。
public struct TimelineDayGroup: Identifiable, Hashable, Sendable {
    /// 当天本地零点，用作稳定的分组与滚动标识。
    public let day: Date
    /// 同一天内保持从新到旧的记录顺序。
    public let captures: [CaptureRecord]

    public var id: Date { day }

    public init(day: Date, captures: [CaptureRecord]) {
        self.day = day
        self.captures = captures
    }
}

public enum TimelineGrouping {
    /// 仅返回指定本地自然日内的记录，供时间线按天增量展示。
    public static func captures(
        on day: Date,
        from captures: [CaptureRecord],
        calendar: Calendar = .current
    ) -> [CaptureRecord] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return captures
            .filter { interval.contains($0.createdAt) }
            .sorted { lhs, rhs in lhs.createdAt > rhs.createdAt }
    }

    /// 使用指定日历的自然日边界分组；日期组和组内记录均按从新到旧排序。
    public static func dayGroups(
        for captures: [CaptureRecord],
        calendar: Calendar = .current
    ) -> [TimelineDayGroup] {
        let grouped = Dictionary(grouping: captures) { capture in
            calendar.startOfDay(for: capture.createdAt)
        }

        return grouped.keys
            .sorted(by: >)
            .map { day in
                TimelineDayGroup(
                    day: day,
                    captures: (grouped[day] ?? []).sorted { lhs, rhs in
                        lhs.createdAt > rhs.createdAt
                    }
                )
            }
    }
}
