import SwiftUI

/// A spacious month grid, kept separate from the timeline's day-filtering logic.
struct TimelineCalendarPopover: View {
    let selectedDay: Date
    /// Days before this one cannot be chosen (an end date cannot precede its start date).
    let earliestDay: Date?
    let selectDay: (Date) -> Void
    @State private var displayedMonth: Date
    @Environment(\.dismiss) private var dismiss

    init(selectedDay: Date, earliestDay: Date? = nil, selectDay: @escaping (Date) -> Void) {
        self.selectedDay = selectedDay
        self.earliestDay = earliestDay.map { Calendar.current.startOfDay(for: $0) }
        self.selectDay = selectDay
        _displayedMonth = State(initialValue: Calendar.current.dateInterval(of: .month, for: selectedDay)?.start ?? selectedDay)
    }

    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: .now) }
    private var monthTitle: String {
        let parts = calendar.dateComponents([.year, .month], from: displayedMonth)
        return "\(parts.year ?? 0)年 \(parts.month ?? 1)月"
    }
    private var days: [Date] {
        let first = calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth
        let leadingDays = calendar.component(.weekday, from: first) - 1
        guard let start = calendar.date(byAdding: .day, value: -leadingDays, to: first) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    private var canMoveForward: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: displayedMonth) else { return false }
        return next <= today
    }
    private var canMoveBack: Bool {
        guard let earliestDay else { return true }
        let firstOfEarliest = calendar.dateInterval(of: .month, for: earliestDay)?.start ?? earliestDay
        return displayedMonth > firstOfEarliest
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Text(monthTitle)
                    .font(.system(size: 20, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                monthButton(offset: -1, symbol: "chevron.up", title: "上个月")
                    .disabled(!canMoveBack)
                monthButton(offset: 1, symbol: "chevron.down", title: "下个月")
                    .disabled(!canMoveForward)
            }
            .padding(.horizontal, 8)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(Array(["日", "一", "二", "三", "四", "五", "六"].enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RecallPalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .accessibilityHidden(true)
                }
                ForEach(days, id: \.self) { day in
                    dayButton(day)
                }
            }
        }
        .padding(16)
        .frame(width: 336)
        .background(RecallPalette.background)
        .onExitCommand { dismiss() }
    }

    private func monthButton(offset: Int, symbol: String, title: String) -> some View {
        Button {
            if let month = calendar.date(byAdding: .month, value: offset, to: displayedMonth) {
                displayedMonth = month
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RecallPalette.secondary)
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func dayButton(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isCurrentMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        let isFuture = day > today
        let isTooEarly = earliestDay.map { calendar.startOfDay(for: day) < $0 } ?? false
        return Button {
            selectDay(day)
            dismiss()
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isSelected ? RecallPalette.onAccent : (isCurrentMonth && !isFuture && !isTooEarly ? RecallPalette.text : RecallPalette.secondary.opacity(0.6)))
                .frame(width: 34, height: 34)
                .background(isSelected ? RecallPalette.accent : Color.clear, in: Circle())
                .overlay {
                    if isToday && !isSelected {
                        Circle().stroke(RecallPalette.accent.opacity(0.65), lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture || isTooEarly)
        .accessibilityLabel(day.formatted(.dateTime.year().month().day().weekday(.wide)))
        .accessibilityValue(isSelected ? "已选择" : (isToday ? "今天" : ""))
        .help(day.formatted(date: .complete, time: .omitted))
    }
}


/// A date field that opens the same month grid as the timeline, replacing the system stepper field.
struct CalendarDateField: View {
    let title: String
    @Binding var date: Date
    var earliest: Date? = nil
    @State private var isOpen = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(RecallPalette.text)
            Button { isOpen.toggle() } label: {
                HStack(spacing: 8) {
                    Text(date.formatted(.dateTime.year().month().day())).fontWeight(.medium)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(RecallPalette.secondary)
                }
            }
            .buttonStyle(.bordered)
            .help("选择\(title)")
            .accessibilityLabel(title)
            .accessibilityValue(date.formatted(date: .complete, time: .omitted))
            .popover(isPresented: $isOpen, arrowEdge: .top) {
                TimelineCalendarPopover(selectedDay: date, earliestDay: earliest) { day in
                    date = Calendar.current.startOfDay(for: day)
                    isOpen = false
                }
            }
        }
        .fixedSize()
    }
}
