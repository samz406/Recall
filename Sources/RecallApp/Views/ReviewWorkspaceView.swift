import SwiftUI
import RecallKit

/// One place for time-based reading, with saved content before generation controls.
struct ReviewWorkspaceView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var period = false
    @State private var composing = false
    var initialPeriod = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecallPageHeader(title: "回顾", subtitle: "回看一天、一周或一个月里值得记住的变化") {
                if period {
                    Button(RecallLocalization.both("写一份回顾", "Create a review")) { composing = true }.buttonStyle(.borderedProminent)
                }
            }
            HStack(spacing: 24) {
                choice(RecallLocalization.both("按天", "Daily"), value: false)
                choice(RecallLocalization.both("按周 / 月", "Weekly / monthly"), value: true)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 14)
            Divider()
            if period { WeeklyReviewView(showsComposer: $composing).environmentObject(model).padding(24) }
            else { DailySummariesView(embedded: true).environmentObject(model) }
        }
        .onAppear { period = initialPeriod || model.weeklyReportToOpen != nil || model.reviewTopicToOpen != nil }
        .onChange(of: model.weeklyReportToOpen) { _, id in if id != nil { period = true } }
        .onChange(of: model.reviewTopicToOpen) { _, id in if id != nil { period = true } }
        .onChange(of: model.dailyToOpen) { _, id in if id != nil { period = false } }
    }
    private func choice(_ title: String, value: Bool) -> some View {
        Button { period = value } label: {
            Text(title).font(.headline).foregroundStyle(period == value ? RecallPalette.accent : RecallPalette.secondary)
                .padding(.vertical, 9).overlay(alignment: .bottom) { if period == value { Rectangle().fill(RecallPalette.accent).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(period == value ? .isSelected : [])
    }
}
