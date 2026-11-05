import RecallKit
import SwiftUI

extension RecallAppModel {
    func setKeepText(_ id: UUID, enabled: Bool) {
        Task {
            do { try await store.setKeepText(id: id, enabled: enabled); state = await store.snapshot() }
            catch { recordError(error, source: "Retention", message: "保存保留设置失败") }
        }
    }
    func localMaintenance(retry: Bool = false) async {
        do {
            if retry { try await store.retryArchiveBackup() }
            let result = try await store.retryPendingFileCleanup()
            pendingFileCleanupCount = result.pendingCount
            archiveBackupPending = await store.backupPending
            state = await store.snapshot()
        } catch { recordError(error, source: "Data", message: "本地备份或清理未完成，请重试") }
    }
}

struct LocalArchiveSafetyCard: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var backup: ArchiveBackup?
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(RecallLocalization.both("保存与清理", "Storage & cleanup")).font(.headline).foregroundStyle(RecallPalette.accent)
            Text(RecallLocalization.both("普通记录默认保留文字 90 天、截图 7 天。可在记录管理调整期限；重要记录可在详情中设为长期保留文字。", "By default, text is kept for 90 days and screenshots for 7 days. Change periods in Record management, or keep important text indefinitely from record details.")).font(.callout).foregroundStyle(RecallPalette.secondary)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(RecallLocalization.both(backup == nil || model.archiveBackupPending ? "自动备份待完成" : "已保存可校验的本地备份", backup == nil || model.archiveBackupPending ? "Local backup pending" : "Verified local backup saved"), systemImage: "externaldrive.badge.checkmark")
                    if let backup { Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(RecallPalette.secondary) }
                    Text(RecallLocalization.both("仅保留最新副本，不含 API Key；删除后不会保留可恢复的旧版本。", "Only the latest mirror is kept, without API keys. Deleted content is not retained in older restore points.")).font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button(RecallLocalization.text("重试")) { Task { await load(retry: true) } }.disabled(working)
            }
            if model.pendingFileCleanupCount > 0 {
                Label(RecallLocalization.both("仍有 \(model.pendingFileCleanupCount) 项文件清理未完成，将自动重试。", "\(model.pendingFileCleanupCount) file cleanup items remain. Recall will retry automatically."), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(RecallPalette.warning)
            }
            if working { ProgressView().controlSize(.small) }
        }.recallSurface().task { await load() }
    }
    @MainActor private func load(retry: Bool = false) async {
        guard !working else { return }
        working = true
        await model.localMaintenance(retry: retry)
        backup = await model.store.recoveryBackups().first
        working = false
    }
}
