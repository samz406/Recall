import SwiftUI
import RecallKit

/// Shared by the active list and history: failure, cancellation and empty success never look alike.
struct ReminderDiscoveryStatusView: View {
    @EnvironmentObject private var model: RecallAppModel
    var body: some View {
        Group {
            switch model.reminderDiscoveryStatus {
            case .searching:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.reminderDiscoveryProgress.phase)
                        if model.reminderDiscoveryProgress.totalRecords > 0 {
                            Text("已保存 \(model.reminderDiscoveryProgress.completedRecords)/\(model.reminderDiscoveryProgress.totalRecords) 条记录的分析").font(.caption)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(RecallLocalization.text("停止")) { model.cancelReminderDiscovery() }
                }
            case .failed(let message), .cancelled(let message), .unavailable(let message), .partial(let message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(RecallLocalization.text("继续发现")) { model.retryReminderDiscovery() }
                }
            default: savedStatus
            }
        }.font(.system(size: 12)).foregroundStyle(RecallPalette.secondary)
    }
    private var savedStatus: some View {
        let checkpoint = model.state.reminderDiscoveryCheckpoint
        let marks = model.state.reminderLearningProfile.reviewedDailyFingerprints ?? [:]
        let reports = model.state.dailySummaries.filter { marks[$0.id.uuidString] != nil }
        let latest = reports.max { $0.day < $1.day }
        let paused = model.state.reminderLearningProfile.reviewDiscoveryEnabled == false
        return HStack(spacing: 8) {
            if paused { Text(RecallLocalization.text("已暂停从每日回顾更新提醒")) }
            else if let latest {
                Text(RecallLocalization.text("已同步每日回顾 · ") + latest.day.formatted(.dateTime.month().day()))
            } else { Text(RecallLocalization.text("生成每日回顾后，明确行动会自动进入待确认")) }
            if (checkpoint.earlierEligibleCount ?? 0) > 0 {
                Button(RecallLocalization.text("继续扫更早记录")) { model.discoverReminders(force: false, extendEarlier: true) }
                    .buttonStyle(.plain).foregroundStyle(RecallPalette.accent)
            }
            if let count = checkpoint.unconfirmedRecordCount, count > 0 {
                Text("\(count) 条记录尚未核对完整")
                Button(RecallLocalization.text("继续发现")) { model.retryReminderDiscovery() }
            }
        }
    }
}
