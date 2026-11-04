import SwiftUI
import RecallKit

/// Shared month grid with the timeline, but future days are allowed and the chosen clock time is retained.
struct ReminderDateTimeField: View {
    @Binding var date: Date
    @State private var showsCalendar = false

    var body: some View {
        HStack(spacing: 12) {
            Text(RecallLocalization.text("提醒时间"))
            Button { showsCalendar.toggle() } label: {
                Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    .foregroundStyle(RecallPalette.accent)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(RecallLocalization.both("选择提醒日期", "Choose reminder date"))
            .popover(isPresented: $showsCalendar) {
                TimelineCalendarPopover(selectedDay: date, earliestDay: .now, latestDay: nil) { day in
                    date = Self.moving(date, to: day)
                    showsCalendar = false
                }
            }
            DatePicker(RecallLocalization.both("时间", "Time"), selection: $date, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field).labelsHidden().fixedSize()
                .accessibilityLabel(RecallLocalization.both("提醒时刻", "Reminder time"))
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
