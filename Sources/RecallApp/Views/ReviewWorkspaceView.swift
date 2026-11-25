import SwiftUI
import RecallKit

/// One place for time-based reading, with saved content before generation controls.
struct ReviewWorkspaceView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var period = false
    @State private var composing = false
    var initialPeriod = false
    var showsHeader = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                RecallPageHeader(title: "回顾", subtitle: "回看一天、一周或一个月里值得记住的变化") { EmptyView() }
            }
            if period {
                // Daily mode renders this picker inside its own action row so the
                // two controls share one line instead of stacking.
                HStack(spacing: 16) {
                    ReviewPeriodPicker(isPeriod: $period)
                    Spacer()
                    Button(RecallLocalization.both("写一份回顾", "Create a review")) { composing = true }.buttonStyle(.bordered)
                }.padding(.horizontal, 24).padding(.vertical, 10)
                Divider()
                WeeklyReviewView(showsComposer: $composing).environmentObject(model).padding(24)
            } else {
                DailySummariesView(embedded: true, periodBinding: $period).environmentObject(model)
            }
        }
        .onAppear { period = initialPeriod || model.weeklyReportToOpen != nil || model.reviewTopicToOpen != nil }
        .onChange(of: model.weeklyReportToOpen) { _, id in if id != nil { period = true } }
        .onChange(of: model.reviewTopicToOpen) { _, id in if id != nil { period = true } }
        .onChange(of: model.navigationRevision) { _, _ in
            if case .daily = model.destination { period = false }
            if case .review = model.destination { period = true }
        }
        .onChange(of: model.dailyToOpen) { _, id in if id != nil { period = false } }
    }
}

/// Daily / weekly switch. A segmented control is quieter than underlined text
/// tabs and fits on the same line as the date picker.
struct ReviewPeriodPicker: View {
    @Binding var isPeriod: Bool
    var body: some View {
        Picker("", selection: $isPeriod) {
            Text(RecallLocalization.both("按天", "Daily")).tag(false)
            Text(RecallLocalization.both("按周", "Weekly")).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 148)
        .accessibilityLabel(RecallLocalization.both("回顾范围", "Review range"))
    }
}
