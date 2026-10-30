import Foundation
import RecallKit

extension RecallLayoutPreviews {
    @MainActor static func verifyReminderHistoryActions() async throws {
        let history = ReminderCandidate(title: "核对合成文档", detail: "合成 UI 操作验收", confidence: 1, status: .dismissed, origin: .manual)
        let model = RecallAppModel(previewState: RecallState(reminders: [history]))
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        let stateURL = model.storage.stateURL, backup = stateURL.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: stateURL, to: backup)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
        model.deleteReminderHistory([history.id], onlyDismissed: true)
        try await waitForHistoryAction(model)
        guard model.noticeMessage?.contains("未完成") == true,
              model.state.reminders.count == 1,
              model.diagnosticEntries.last?.level == .error else { throw HistoryActionFailure.failed("写入失败没有通过页面提示并保留历史") }
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.moveItem(at: backup, to: stateURL)
        model.restoreReminderHistory([history.id])
        try await waitForHistoryAction(model)
        guard model.state.reminders.first?.status == .proposed,
              model.state.reminders.first?.scheduledAt == nil,
              model.noticeMessage?.contains("待确认") == true else { throw HistoryActionFailure.failed("恢复没有回到待确认并反馈结果") }
        print("PASS: native reminder-history action entry points report failed writes, retain records and restore without scheduling notifications")
    }
    @MainActor private static func waitForHistoryAction(_ model: RecallAppModel) async throws {
        for _ in 0..<300 {
            if !model.isUpdatingReminderHistory { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HistoryActionFailure.failed("合成历史操作超时")
    }
    private enum HistoryActionFailure: Error { case failed(String) }
}
