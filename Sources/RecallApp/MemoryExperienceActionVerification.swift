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
              model.chatScope.applying(to: model.state).captures.contains(where: { $0.id == note.id }) else {
            throw MemoryExperienceFailure(errorDescription: "继续问未携带主题")
        }
        for _ in 0..<2_000 {
            if !model.isThinking { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard model.state.messages.count >= messages.count + 2, !model.isThinking,
              model.state.messages.last(where: { $0.role == .user })?.content.contains(topic.title) == true else {
            throw MemoryExperienceFailure(errorDescription: "继续问没有自动发起带主题的提问")
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
        guard let personalSource = memory.sourceIDs.first, model.chatSources.record(id: personalSource)?.memoryDirective != nil else {
            throw MemoryExperienceFailure(errorDescription: "记住的回执缺少来源或撤销入口")
        }
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

        // Verify undo of completion, rename, shelve, and custom-question topic ask.
        model.undoTopicAction()
        for _ in 0..<400 {
            if model.matterFiles.first?.latest.status == .progressed && !model.isBuildingMatters { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let reopenedTopic = model.matterFiles.first, reopenedTopic.latest.status == .progressed else {
            throw MemoryExperienceFailure(errorDescription: "底部撤销入口未能恢复已完成主题")
        }
        guard await model.renameTopic(reopenedTopic, to: "Atlas 核心方案核对"),
              model.matterFiles.first?.title == "Atlas 核心方案核对" else {
            throw MemoryExperienceFailure(errorDescription: "主题重命名未能即时刷新列表标题")
        }
        let resumeItem = LocalBriefing.ResumeItem(
            id: "matter-" + reopenedTopic.id,
            kind: .openMatter,
            title: "Atlas 方案核对进展",
            detail: "进行中 · 下一轮继续验证",
            destination: .topic(reopenedTopic.id),
            date: date,
            status: .progressed,
            summaryText: "下一轮继续验证",
            topicID: reopenedTopic.id,
            topicTitle: "Atlas 核心方案核对",
            evidenceIDs: reopenedTopic.evidenceIDs
        )
        guard await model.shelveResumeItem(resumeItem),
              model.topicActionUndo?.label.contains("已先放下") == true,
              TopicListPresentation.lifecycle(for: model.matterFiles[0], registry: model.state.topicRegistry) == .dormant else {
            throw MemoryExperienceFailure(errorDescription: "从今天先放下未能将主题设为已搁置并生成撤销条")
        }
        model.undoTopicAction()
        for _ in 0..<400 {
            if TopicListPresentation.lifecycle(for: model.matterFiles[0], registry: model.state.topicRegistry) == .active { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard TopicListPresentation.lifecycle(for: model.matterFiles[0], registry: model.state.topicRegistry) == .active else {
            throw MemoryExperienceFailure(errorDescription: "先放下后一键撤销未恢复推进中状态")
        }

        // Verify reopenTopic + undo, and opening scoped topic session without auto-sending a robotic question.
        guard await model.completeMatter(model.matterFiles[0]),
              await model.reopenTopic(model.matterFiles[0]) else {
            throw MemoryExperienceFailure(errorDescription: "已完成主题恢复跟进失败")
        }
        for _ in 0..<400 {
            if !model.isBuildingMatters && model.matterFiles.first?.latest.status == .progressed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let userCountBeforeSilentOpen = model.state.messages.filter { $0.role == .user }.count
        model.openTopicConversation(reopenedTopic.id, question: nil)
        try await Task.sleep(for: .milliseconds(50))
        guard model.state.messages.filter({ $0.role == .user }).count == userCountBeforeSilentOpen,
              !model.state.messages.isEmpty,
              !model.isThinking else {
            throw MemoryExperienceFailure(errorDescription: "不输入问题进入主题会话时不应机械自动发送模板提问，且应恢复原主题会话")
        }
        model.openTopicConversation(reopenedTopic.id, question: "上次比较了哪两种方案？")
        for _ in 0..<2_000 {
            if !model.isThinking { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard model.state.messages.last(where: { $0.role == .user })?.content == "上次比较了哪两种方案？" else {
            throw MemoryExperienceFailure(errorDescription: "主题内联自定义提问未发送用户自己的问题")
        }

        print("PASS: native unified-memory actions: readable topic completion, undo, rename, shelve, custom topic ask, About me save/forget without source deletion or global task refresh")
    }
}

extension RecallLayoutPreviews {
    actor TopicSummaryProbe: LLMResponding {
        private var calls = 0
        private var delay = 40
        func setDelay(_ value: Int) { delay = value }
        func count() -> Int { calls }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            calls += 1
            try await Task.sleep(for: .milliseconds(delay))
            let rows = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            let row = rows[0]
            let title = row["title"] as! String
            let data: [String: Any] = ["overview": title, "items": [["section": "progress", "title": title, "detail": row["detail"] as! String,
                "evidence": [["id": row["id"] as! String, "quote": title]]]]]
            return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self), citedCaptureIDs: [])
        }
    }
    @MainActor static func verifyAutomaticTopicSummary() async throws {
        let date = Date.now.addingTimeInterval(-3600)
        let source = try ManualMatterNote(title: "Atlas 自动小结验证", detail: "已完成初步方案核对，仍需验证边界。", status: .progressed, eventAt: date).capture(recordedAt: date)
        var daily = DailySummary(day: Calendar.current.startOfDay(for: date), content: "", sourceCaptureIDs: [source.id], todos: [], generationKind: .cloud)
        daily.ledger = [DailyMatterLedgerEntry(topic: "Atlas 自动小结验证", kind: .matter, status: "inProgress", section: "progress", title: "Atlas 初步方案核对", detail: "已完成初步方案核对，仍需验证边界。", ownedByUser: true,
            quotes: [DailyLedgerQuote(text: source.ocrText, sourceIDs: [source.id], speaker: "user")], evidenceIDs: [source.id], occurredAt: date)]
        var state = RecallState(captures: [source], dailySummaries: [daily])
        // Start the preview with the same stable topic IDs as its reopened store.
        state.topicRegistry = TopicRegistry.migrated(from: state)
        state.privacy.cloudUseEnabled = true
        let probe = TopicSummaryProbe()
        let model = try RecallAppModel(previewState: state, topicReviewResponder: probe)
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        guard await probe.count() == 0, model.state.topicReviews.isEmpty else { throw MemoryExperienceFailure(errorDescription: "默认关闭仍执行了后台模型请求") }
        var settings = model.state.memoryKnowledgeSettings; settings.automaticTopicSummaries = true
        model.updateMemorySettings(settings)
        for _ in 0..<1000 {
            if model.state.topicReviews.count == 1 && model.generatingTopicID == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let old = model.state.topicReviews.first, await probe.count() == 1 else { throw MemoryExperienceFailure(errorDescription: "启用自动小结没有完成一次可用更新") }
        model.rebuildMatterFiles()
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(5)) }
        guard await probe.count() == 1 else { throw MemoryExperienceFailure(errorDescription: "相同主题输入重复调用模型") }
        await probe.setDelay(600)
        let updatedDate = Date.now.addingTimeInterval(-10)
        let update = ManualMatterNote(title: source.manualMatter!.title, detail: "补充了新的边界用例，等待验收。", status: .pending, eventAt: updatedDate)
        guard await model.saveManualMatter(update) else { throw MemoryExperienceFailure(errorDescription: "补充进展未保存") }
        for _ in 0..<300 {
            if await probe.count() == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await probe.count() == 2, let current = model.matterFiles.first,
              current.latest.detail.contains("新的边界用例"), TopicReading(file: current, review: model.state.topicReviews.first).overview.contains("新的边界用例"), model.state.topicReviews.first?.overview == old.overview else {
            throw MemoryExperienceFailure(errorDescription: "增量更新未启动，或旧小结/新进展在更新期间不可读")
        }
        settings.automaticTopicSummaries = false
        model.updateMemorySettings(settings)
        for _ in 0..<300 {
            if model.generatingTopicID == nil && model.state.memoryKnowledgeSettings.automaticTopicSummaries == false { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard model.generatingTopicID == nil, model.state.topicReviews.first?.overview == old.overview,
              model.state.topicReviews.first?.inputFingerprint == old.inputFingerprint else {
            throw MemoryExperienceFailure(errorDescription: "暂停自动更新后迟到结果覆盖了原小结")
        }
        print("PASS: native automatic topic summaries: opt-in, one request per input, incremental update, readable old content and same-day progress, pause/cancel prevents late commits")
    }
}
