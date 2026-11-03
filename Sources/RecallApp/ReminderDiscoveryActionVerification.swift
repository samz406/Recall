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
    private actor UncertainReminderModel: LLMResponding {
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            let input = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [String: Any]
            let sources = input["sources"] as! [[String: Any]]
            let blocks = sources.flatMap { $0["blocks"] as! [[String: Any]] }.filter { $0["contextOnly"] as? Bool != true }
            let object: [String: Any] = ["actions": [], "resolutions": [],
                "coverage": blocks.map { ["blockID": $0["id"]!, "disposition": "uncertain"] }]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    @MainActor static func verifyReminderDiscoveryActions() async throws {
        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970)), sourceAppName: "合成聊天",
            contentHash: "synthetic-action", ocrText: "[聊天·自己] 我会整理合成验收清单。")
        let prior = ReminderCandidate(title: "保留合成候选", detail: "未经确认，不安排通知。", sourceCaptureIDs: [source.id], confidence: 0.7, createdAt: source.createdAt)
        let state = RecallState(captures: [source], reminders: [prior], privacy: PrivacySettings(cloudUseEnabled: true),
            llmConfiguration: LLMConfiguration(provider: .openAICompatible, baseURLString: "https://model.invalid/v1", model: "synthetic", apiKey: "synthetic-not-a-key"))
        let model = RecallAppModel(previewState: state)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        let backgroundProbe = ReminderModelProbe(slow: false)
        model.discoverReminders(force: false, announce: false, responder: backgroundProbe)
        try await Task.sleep(for: .milliseconds(25))
        guard await backgroundProbe.started() == false else { throw DiscoveryActionFailure.failed("后台触发仍在重复调用原文提醒分析") }
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
        model.discoverReminders(force: false, responder: UncertainReminderModel())
        try await waitForDiscovery(model)
        guard case .partial = model.reminderDiscoveryStatus, model.noticeMessage?.contains("尚未核对完整") == true,
              model.state.reminders == [prior], model.state.reminderDiscoveryCheckpoint.processedCaptureHashes.isEmpty else {
            throw DiscoveryActionFailure.failed("不确定结果被显示为没有待办，或不能继续核对")
        }
        print("PASS: native reminder-discovery entry points distinguish partial results, model failure and cancellation, preserving unconfirmed reminders without notifications")
    }
    @MainActor private static func waitForDiscovery(_ model: RecallAppModel) async throws {
        for _ in 0..<400 {
            if case .searching = model.reminderDiscoveryStatus { try await Task.sleep(for: .milliseconds(5)) }
            else { return }
        }
        throw DiscoveryActionFailure.failed("合成模型操作超时")
    }
}
