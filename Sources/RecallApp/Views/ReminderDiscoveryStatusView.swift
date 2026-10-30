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
                    Button("停止") { model.cancelReminderDiscovery() }
                }
            case .failed(let message), .cancelled(let message), .unavailable(let message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("重新发现") { model.proposeReminders() }
                }
            default: savedStatus
            }
        }.font(.system(size: 12)).foregroundStyle(RecallPalette.secondary)
    }
    private var savedStatus: some View {
        let checkpoint = model.state.reminderDiscoveryCheckpoint
        return HStack(spacing: 8) {
            Text(checkpoint.failureReason != nil ? "上次分析未完成" : (checkpoint.lastRunAt == nil ? "尚未进行模型分析" : (checkpoint.extractorVersion == ModelReminderDiscovery.version ? "已用模型核对待办" : "上次使用本地规则检查")))
            if let date = checkpoint.lastRunAt { Text("· " + date.formatted(date: .omitted, time: .shortened)) }
            Menu("查看检查详情") {
                if let failure = checkpoint.failureReason { Text(failure) }
                Text("本次已分析 \(checkpoint.analyzedRecordCount) 条记录")
                Text("共有 \(checkpoint.eligibleRecordCount) 条记录允许参与")
                Text("\(checkpoint.unchangedRecordCount ?? 0) 条内容未变化，复用上次检查")
                Text("\(checkpoint.excludedRecordCount ?? 0) 条因来源或参与设置未纳入")
                Text("新增 \(checkpoint.discoveredCount) 项待确认；忽略和已处理结果继续生效")
                if let openPending { Button("查看待确认", action: openPending) }
                Button("重新发现") { model.proposeReminders() }
            }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(RecallPalette.accent)
        }
    }
}
