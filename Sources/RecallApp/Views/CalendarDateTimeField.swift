import SwiftUI
import RecallKit

/// Chooses a day in Recall's month grid and lets the user edit the clock time separately.
struct CalendarDateTimeField: View {
    let title: String
    @Binding var date: Date
    var earliestDay: Date? = nil
    @State private var showsCalendar = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Button { showsCalendar.toggle() } label: {
                Label(date.formatted(.dateTime.locale(RecallLocalization.locale).year().month(.abbreviated).day()), systemImage: "calendar")
                    .foregroundStyle(RecallPalette.accent)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(RecallLocalization.both("\(title) · 日期", "\(title), date"))
            .accessibilityValue(date.formatted(.dateTime.locale(RecallLocalization.locale).year().month(.wide).day()))
            .popover(isPresented: $showsCalendar) {
                TimelineCalendarPopover(selectedDay: date, earliestDay: earliestDay, latestDay: nil) { day in
                    date = Self.moving(date, to: day)
                    showsCalendar = false
                }
            }
            let timeLabel = RecallLocalization.both("\(title) · 时刻", "\(title), time")
            DatePicker(timeLabel, selection: $date, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field).labelsHidden().fixedSize()
                .accessibilityLabel(timeLabel)
            Spacer(minLength: 0)
        }
    }

    static func moving(_ date: Date, to day: Date, calendar: Calendar = .current) -> Date {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        return calendar.date(bySettingHour: clock.hour ?? 9, minute: clock.minute ?? 0, second: 0, of: day) ?? day
    }
}

struct ReminderCalendarPreview: View {
    var body: some View {
        TimelineCalendarPopover(selectedDay: Calendar.current.date(byAdding: .month, value: 1, to: .now)!, earliestDay: .now, latestDay: nil) { _ in }
    }
}
