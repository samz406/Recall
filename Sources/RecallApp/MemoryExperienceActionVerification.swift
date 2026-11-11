import Foundation
import RecallKit

extension RecallLayoutPreviews {
    private struct MemoryExperienceFailure: LocalizedError { let errorDescription: String? }
    @MainActor static func verifyMemoryExperienceActions() async throws {
        let date = Date.now.addingTimeInterval(-3600)
        let note = try ManualMatterNote(title: "Atlas 方案核对", detail: "已比较两种方案，下一轮继续验证边界。", status: .progressed, eventAt: date).capture(recordedAt: date)
        let model = try RecallAppModel(previewState: RecallState(captures: [note]))
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        guard let topic = model.matterFiles.first else { throw MemoryExperienceFailure(errorDescription: "没有建立主题详情夹具") }
        let messages = model.state.messages
        model.startTopicConversation(topic.id)
        guard model.chatScope.topicID == topic.id, model.openAskRequested,
              model.state.messages == messages, !model.isThinking else {
            throw MemoryExperienceFailure(errorDescription: "继续问未携带主题，或自动发送了固定问题")
        }
        guard await model.completeMatter(topic), model.matterFiles.first?.latest.detail == topic.latest.detail,
              TopicReading(file: model.matterFiles[0]).overview == topic.resumeText else {
            throw MemoryExperienceFailure(errorDescription: "标记完成覆盖了可读内容")
        }
        guard await model.saveMemoryAgreement(content: "以后回答简洁一点，先给结论", scope: .global) else {
            throw MemoryExperienceFailure(errorDescription: "关于我入口未保存")
        }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        guard let memory = model.state.memoryKnowledge.claims.first(where: { $0.kind.isPersonal && $0.usable() }) else { throw MemoryExperienceFailure(errorDescription: "保存成功后未显示个人信息") }
        let sources = model.state.captures, revision = model.memoryWorkspace?.revision
        model.retireMemory(memory)
        for _ in 0..<500 {
            if !model.state.memoryKnowledge.claims.contains(where: { $0.id == memory.id && $0.usable() }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard model.state.captures == sources, model.memoryWorkspace?.revision == revision,
              !model.state.memoryKnowledge.claims.contains(where: { $0.id == memory.id && $0.usable() }),
              model.matterFiles.first?.latest.detail == topic.latest.detail,
              model.tasks.isEmpty, !model.isGeneratingDailySummary, !model.isGeneratingWeeklyReview else {
            throw MemoryExperienceFailure(errorDescription: "不再记住误删了来源、重新整理全库或未停止参考")
        }
        print("PASS: native unified-memory actions: readable topic completion, own question with topic scope, About me save/forget without source deletion or global task refresh")
    }
}
