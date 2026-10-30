import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private actor ReminderModelProbe: LLMResponding {
        let slow: Bool
        var entered = false
        init(slow: Bool) { self.slow = slow }
        func started() -> Bool { entered }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            entered = true
            if slow { try await Task.sleep(for: .seconds(30)) }
            throw URLError(.notConnectedToInternet)
        }
    }
    private enum DiscoveryActionFailure: Error { case failed(String) }
    @MainActor static func verifyReminderDiscoveryActions() async throws {
        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970)), sourceAppName: "合成聊天",
            contentHash: "synthetic-action", ocrText: "[聊天·自己] 我会整理合成验收清单。")
        let prior = ReminderCandidate(title: "保留合成候选", detail: "未经确认，不安排通知。", sourceCaptureIDs: [source.id], confidence: 0.7, createdAt: source.createdAt)
        let state = RecallState(captures: [source], reminders: [prior], privacy: PrivacySettings(cloudUseEnabled: true),
            llmConfiguration: LLMConfiguration(provider: .openAICompatible, baseURLString: "https://model.invalid/v1", model: "synthetic", apiKey: "synthetic-not-a-key"))
        let model = RecallAppModel(previewState: state)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        model.discoverReminders(force: true, responder: ReminderModelProbe(slow: false))
        try await waitForDiscovery(model)
        guard case .failed = model.reminderDiscoveryStatus, model.noticeMessage?.contains("未完成") == true,
              model.state.reminders == [prior], model.diagnosticEntries.last?.level == .error else {
            throw DiscoveryActionFailure.failed("模型失败没有显示错误或覆盖了旧候选")
        }
        let probe = ReminderModelProbe(slow: true)
        model.discoverReminders(force: true, responder: probe)
        for _ in 0..<200 { if await probe.started() { break }; try await Task.sleep(for: .milliseconds(5)) }
        model.cancelReminderDiscovery()
        try await waitForDiscovery(model)
        guard case .cancelled = model.reminderDiscoveryStatus, model.state.reminders == [prior],
              model.state.reminders[0].scheduledAt == nil else {
            throw DiscoveryActionFailure.failed("停止没有取消模型请求或误安排通知")
        }
        print("PASS: native reminder-discovery entry points report model failure, cancel promptly and preserve unconfirmed reminders without notifications")
    }
    @MainActor private static func waitForDiscovery(_ model: RecallAppModel) async throws {
        for _ in 0..<400 {
            if case .searching = model.reminderDiscoveryStatus { try await Task.sleep(for: .milliseconds(5)) }
            else { return }
        }
        throw DiscoveryActionFailure.failed("合成模型操作超时")
    }
}
