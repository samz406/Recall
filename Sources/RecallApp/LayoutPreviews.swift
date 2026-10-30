import AppKit
import SwiftUI
import RecallKit

/// Opt-in CI-only rendering: temporary synthetic archive, no capture, notifications or model requests.
@MainActor
enum RecallLayoutPreviews {
    static func fixture() async throws -> RecallState {
        var state = RecallState()
        let now = Date.now
        for index in 0..<12 {
            let title = ["Atlas 发布流程优化", "Nova 图表边界验证", "每周阅读与笔记"][index % 3]
            let note = ManualMatterNote(title: title, detail: "合成界面验收内容：完成了方案核对，仍需确认后续安排。", status: index % 4 == 0 ? .blocked : .progressed, eventAt: now.addingTimeInterval(-Double(index * 3600)), reviewCategory: index % 3 == 2 ? .learning : .work)
            var record = try note.capture(recordedAt: now.addingTimeInterval(-Double(index * 3600)))
            record.sourceAppName = index % 2 == 0 ? "合成聊天" : "合成浏览器"
            state.captures.append(record)
        }
        for index in 0..<6 {
            let proof = state.captures[index]
            var daily = DailySummary(day: now.addingTimeInterval(-Double(index * 86_400)), content: "合成回顾正文", sourceCaptureIDs: [proof.id], todos: [], generationKind: .cloud)
            daily.modelOverview = "完成页面方案核对，保留了进展、阻塞和明确的后续安排。"
            daily.items = [DailySummaryItem(section: .progress, title: ["Atlas 发布流程页面核对", "Nova 图表边界验证", "每周阅读与笔记"][index % 3], detail: "界面间距与操作入口已经核对；生产发布尚未进行。", evidenceIDs: [proof.id], knowledge: DailyItemKnowledge(topic: ["Atlas 发布流程", "Nova 图表边界", "每周阅读与笔记"][index % 3], kind: .matter, status: index == 0 ? "blocked" : (index == 1 ? "inProgress" : "completed"), ownedByUser: true, quotes: [proof.ocrText], category: "work")),
                           DailySummaryItem(section: .insights, title: "发布状态需分别验证", detail: "方案核对完成与生产发布是不同环节，应保留各自的状态。", evidenceIDs: [proof.id])]
            state.dailySummaries.append(daily)
        }
        for text in ["记住：以后回答简洁一点，先结论后细节", "记住：以后工作周报只写工作内容"] {
            let directive = MemoryDirective.parse(text)!
            state.captures.append(CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "明确约定", contentHash: UUID().uuidString, ocrText: directive.content, textOrigin: .userInput, memoryDirective: directive))
        }
        state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        let period = ReviewPeriod.make(.recentSeven, at: now)
        let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .personal))
        state.weeklyReports = [report]
        var stale = report; stale.id = UUID(); stale.invalidate(); state.weeklyReports.append(stale)
        state.messages = [ConversationMessage(role: .user, content: "我这周在 Atlas 上有什么进展？"),
                          ConversationMessage(role: .assistant, content: "Atlas 的页面方案已完成核对，生产发布仍待确认。\n\n可以先查看发布状态，再继续安排验收。", citations: [state.captures[0].id, state.captures[1].id]),
                          ConversationMessage(role: .user, content: "明白了")]
        state.reminders = [ReminderCandidate(title: "核对 Atlas 发布状态", detail: "合成验收候选，不安排实际通知。", sourceCaptureIDs: [state.captures[0].id], confidence: 0.9)]
        addHistory(to: &state, now: now)
        return state
    }
    private static func addHistory(to state: inout RecallState, now: Date) {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let first = state.captures[0], second = state.captures[1]
        func history(_ title: String, _ status: ReminderStatus, _ date: Date, _ source: CaptureRecord) -> ReminderCandidate {
            ReminderCandidate(title: title, detail: "从合成内容识别；创建前请确认。", sourceCaptureIDs: [source.id], confidence: 0.8,
                status: status, createdAt: date.addingTimeInterval(-3_600), updatedAt: date, origin: .discovered,
                completedAt: status == .completed ? date : nil, dismissedUntil: status == .dismissed ? date.addingTimeInterval(30 * 86_400) : nil)
        }
        state.reminders += [
            history("核对 Atlas 发布流程的验收边界，整理全部验证结果与后续安排，保留完整记录供下一轮方案核对时使用", .dismissed, now.addingTimeInterval(-60), first),
            history("整理 Nova 图表边界验证结果", .dismissed, now.addingTimeInterval(-600), second),
            history("检查每周阅读笔记的索引", .dismissed, now.addingTimeInterval(-1_200), first),
            history("提交 Atlas 验收报告", .completed, yesterday.addingTimeInterval(16 * 3_600), first),
            history("提交 Atlas 验收报告", .completed, yesterday.addingTimeInterval(16 * 3_600 - 60), first),
            history("核对 Nova 留白方案", .dismissed, yesterday.addingTimeInterval(15 * 3_600), second),
            history("整理每周学习笔记", .completed, yesterday.addingTimeInterval(11 * 3_600), first),
            history("预订合成会议室", .cancelled, yesterday.addingTimeInterval(9 * 3_600), second)
        ]
        for offset in 0..<195 {
            let status: ReminderStatus = offset < 38 ? .completed : (offset % 10 == 0 ? .cancelled : .dismissed)
            state.reminders.append(history("核对合成验收记录 \(offset + 1)", status,
                yesterday.addingTimeInterval(-86_400 - Double(offset * 3_600)), offset % 2 == 0 ? first : second))
        }
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint(lastRunAt: now.addingTimeInterval(-120), eligibleRecordCount: state.captures.count, analyzedRecordCount: 2, discoveredCount: 1)
    }
    static func run() async throws {
        let args = CommandLine.arguments
        let index = args.firstIndex(of: "--layout-previews")!
        let directory = URL(fileURLWithPath: args.count > index + 1 ? args[index + 1] : "/tmp/recall-layout-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try await RecallChatInput.verifyKeyboardBehavior()
        try await verifyAppearanceAndConnection()
        let model = RecallAppModel(previewState: try await fixture())
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        while model.isBuildingMatters { try await Task.sleep(for: .milliseconds(10)) }
        let defaults = UserDefaults(suiteName: "im.recall.synthetic-layout")!
        defer { defaults.removePersistentDomain(forName: "im.recall.synthetic-layout") }
        let names = ["daily", "topics", "period", "period-stale", "knowledge", "knowledge-empty", "rules", "reminders", "reminder-history", "reminder-history-hover", "reminder-history-empty", "timeline", "settings", "appearance", "appearance-compact", "model-editor", "model-editor-new", "model-editor-success", "model-editor-failure", "chat", "chat-empty", "navigation"]
        for mode in ["wide", "narrow", "dark"] {
            let width: CGFloat = mode == "narrow" ? 780 : 1050
            defaults.set(mode == "dark" ? "dark" : "system", forKey: RecallAppearance.storageKey)
            for name in names {
                defaults.set(name.hasPrefix("period") ? "周期回顾" : (name.hasPrefix("knowledge") ? "长期记忆" : "记忆主题"), forKey: "recall.memory.tab")
                let saved = model.state
                let savedReportSelection = model.weeklyReportToOpen
                if name == "period-stale" { model.weeklyReportToOpen = model.state.weeklyReports.last?.id }
                if name == "reminder-history-empty" { model.state.reminders.removeAll { $0.status.isHistory } }
                if name == "knowledge-empty" { model.state.memoryKnowledge.claims = [] }
                if name == "chat-empty" { model.state.messages = [ConversationMessage(role: .system, content: "已清空当前会话，可以开始新的对话。")] }
                let pageWidth: CGFloat = name == "navigation" ? width + 196 : (name == "appearance-compact" ? 620 : (name.hasPrefix("model-editor") ? 700 : width))
                let pageHeight: CGFloat = name.hasPrefix("model-editor") ? min(744, (NSScreen.main?.visibleFrame.height ?? 900) - 48) : (name == "appearance-compact" ? 560 : 740)
                let page = RecallRootView.previewPage(name)
                    .environmentObject(model).recallColors().defaultAppStorage(defaults)
                    .environment(\.controlActiveState, .key)
                    .frame(width: pageWidth, height: pageHeight)
                let host = NSHostingView(rootView: page)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
                window.contentView = host; window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(name == "navigation" ? 600 : 150))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PreviewFailure.noImage }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]), data.count > 1000 else { throw PreviewFailure.noImage }
                try data.write(to: directory.appendingPathComponent(mode + "-" + name + ".png"))
                window.orderOut(nil)
                model.state = saved
                model.weeklyReportToOpen = savedReportSelection
            }
        }
        print("PASS: rendered \(names.count * 3) native SwiftUI page previews (wide, minimum detail width, compact settings and dark appearance)")
    }
    private enum PreviewFailure: Error { case noImage }
}
