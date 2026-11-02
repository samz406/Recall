import SwiftUI
import RecallKit

/// Shared by the active list and history: failure, cancellation and empty success never look alike.
struct ReminderDiscoveryStatusView: View {
    @EnvironmentObject private var model: RecallAppModel
    var openPending: (() -> Void)? = nil
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
            case .failed(let message), .cancelled(let message), .unavailable(let message):
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
            Menu("查看检查详情") {
                Text(paused ? "已暂停自动更新，已有提醒保留" : "复用每日回顾中的本人明确承诺，不增加提醒模型调用")
                Text("已处理 \(reports.count) 篇回顾；仍需确认时间后才通知")
                if let openPending { Button(RecallLocalization.text("查看待确认"), action: openPending) }
                Divider()
                Text(RecallLocalization.text("手动深查原始记录"))
                if let failure = checkpoint.failureReason { Text(failure) }
                if let date = checkpoint.lastRunAt { Text(RecallLocalization.text("最近深查：") + date.formatted(date: .abbreviated, time: .shortened)) }
                Text("上次深查 \(checkpoint.analyzedRecordCount) 条；\(checkpoint.eligibleRecordCount) 条允许参与深查")
                Text("\(checkpoint.unchangedRecordCount ?? 0) 条内容未变化，复用上次检查")
                Text("\(checkpoint.excludedRecordCount ?? 0) 条因来源或参与设置未纳入")
                Text("新增 \(checkpoint.discoveredCount) 项待确认；忽略和已处理结果继续生效")
                Button(RecallLocalization.text("手动深查")) { model.proposeReminders() }
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(RecallPalette.accent)
        }
    }
}
