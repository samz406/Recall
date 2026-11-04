import AppKit
import RecallKit
import SwiftUI

@MainActor
final class RecallStartupController: ObservableObject {
    @Published var model: RecallAppModel?
    @Published var failure: String?
    @Published var backups: [ArchiveBackup] = []
    @Published var isWorking = false
    private(set) var storage: RecallStorage?

    init(storage: RecallStorage? = nil, automatic: Bool = true) {
        self.storage = storage
        if automatic { Task { await open() } }
    }
    static func preview() -> RecallStartupController {
        let value = RecallStartupController(automatic: false)
        value.failure = RecallLocalization.both("无法读取本地档案。原始文件已保留。", "The archive could not be read. The original file is preserved.")
        value.backups = [ArchiveBackup(id: "synthetic", createdAt: Date(timeIntervalSince1970: 1_794_000_000), captureCount: 120)]
        return value
    }
    func open() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await Task.yield()
        do {
            if self.storage == nil && CommandLine.arguments.contains("--layout-previews") { model = try RecallAppModel(previewState: RecallState()); return }
            let storage = try self.storage ?? RecallStorage()
            self.storage = storage
            if !FileManager.default.fileExists(atPath: storage.stateURL.path) {
                backups = await Task.detached(priority: .utility) { ArchiveReliability.backups(storage) }.value
            }
            if !FileManager.default.fileExists(atPath: storage.stateURL.path), !backups.isEmpty {
                failure = RecallLocalization.both("原始档案缺失。请选择已校验的备份恢复。", "The archive is missing. Restore a verified backup."); return
            }
            model = try RecallAppModel(storageOverride: storage)
            failure = nil
        } catch {
            failure = error.localizedDescription
            if case .unsupportedVersion? = error as? ArchiveReliabilityError { backups = [] }
            else if let storage { backups = await Task.detached(priority: .utility) { ArchiveReliability.backups(storage) }.value }
        }
    }
    func restore(_ backup: ArchiveBackup) async {
        guard let storage, !isWorking else { return }
        isWorking = true
        do {
            try await Task.detached(priority: .userInitiated) { try ArchiveReliability.restore(backup, storage: storage) }.value
            isWorking = false
            await open()
        } catch { failure = error.localizedDescription; isWorking = false }
    }
    func reveal() { if let storage { NSWorkspace.shared.open(storage.rootURL) } }
}

struct ArchiveRecoveryView: View {
    @ObservedObject var startup: RecallStartupController
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(RecallLocalization.both("打开本地记忆", "Open local memory"), systemImage: "externaldrive.badge.exclamationmark").font(.title2.weight(.semibold))
            if let failure = startup.failure {
                Text(failure).textSelection(.enabled).foregroundStyle(RecallPalette.secondary)
                Text(RecallLocalization.both("原始档案会保留，不会自动创建空白记忆覆盖它。恢复前会隔离损坏文件；备份不含 API Key。", "The original archive is kept; Recall will not replace it with blank memory. Damaged bytes are isolated before recovery. Backups contain no API key.")).font(.callout)
                ForEach(startup.backups) { backup in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(RecallLocalization.both("已校验 · \(backup.captureCount) 条记录", "Verified · \(backup.captureCount) records")).foregroundStyle(RecallPalette.secondary)
                        }
                        Spacer()
                        Button(RecallLocalization.both("恢复这份备份", "Restore backup")) { Task { await startup.restore(backup) } }.buttonStyle(.borderedProminent)
                    }.padding(16).background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                if startup.backups.isEmpty { Text(RecallLocalization.both("没有可用的自动备份。可以打开数据文件夹保留档案，修复后重试。", "No verified backup is available. Open the data folder to preserve the archive, then repair it and retry.")).foregroundStyle(RecallPalette.secondary) }
                HStack {
                    Button(RecallLocalization.both("打开数据文件夹", "Open data folder")) { startup.reveal() }
                    Button(RecallLocalization.text("重试")) { Task { await startup.open() } }
                }
            }
            if startup.isWorking { ProgressView(RecallLocalization.both("正在打开…", "Opening…")) }
        }
        .disabled(startup.isWorking)
        .padding(36).frame(maxWidth: 660).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RecallPalette.background)
    }
}
