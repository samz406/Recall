import Foundation
import RecallKit

/// 主题列表的摘要与分组：摘要取最近一件具体事情，完成与搁置折叠。
enum TopicListVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }

    static func run() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!
        func file(_ id: String, daysAgo: Int, status: WorkEpisodeStatus, headline: String?) -> MatterFile {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            var event = MatterEvent(id: UUID(), title: id, detail: "PR #123 修复 env=FOO 表 t_order 细节",
                recordedAt: day, eventAt: day, status: status, evidenceIDs: [UUID()], nextAction: nil)
            event.headline = headline
            return MatterFile(id: id, title: id, events: [event])
        }

        let withHeadline = TopicReading(file: file("topic:a", daysAgo: 1, status: .progressed,
            headline: "历史气泡误挂思考中表情的问题已定位并修复"))
        try expect(withHeadline.headline == "历史气泡误挂思考中表情的问题已定位并修复",
                   "摘要应使用最近事件的 headline，而不是带执行细节的 detail")

        let withoutHeadline = TopicReading(file: file("topic:b", daysAgo: 1, status: .progressed, headline: nil))
        try expect(withoutHeadline.headline.count <= 60, "没有 headline 时应回退为截断的 detail")
        try expect(!withoutHeadline.headline.isEmpty, "回退摘要不能为空")

        let groups = TopicListPresentation.group([
            file("topic:a", daysAgo: 1, status: .progressed, headline: nil),
            file("topic:b", daysAgo: 2, status: .completed, headline: nil),
            file("topic:c", daysAgo: 30, status: .progressed, headline: nil)
        ], now: now, calendar: calendar)
        try expect(groups.active.map(\.id) == ["topic:a"], "进行中只含近期仍未完成的事项")
        try expect(Set(groups.done.map(\.id)) == ["topic:b", "topic:c"], "已完成与超过 14 天没有动静的归入折叠组")

        let sections = TopicListPresentation.sections([
            file("topic:a", daysAgo: 1, status: .progressed, headline: nil),
            file("topic:b", daysAgo: 2, status: .completed, headline: nil),
            file("topic:c", daysAgo: 30, status: .progressed, headline: nil)
        ], now: now, calendar: calendar)
        try expect(sections.active.map(\.id) == ["topic:a"], "sections 进行中分组错误")
        try expect(sections.dormant.map(\.id) == ["topic:c"], "sections 已搁置应区分超 14 天未完事项")
        try expect(sections.done.map(\.id) == ["topic:b"], "sections 已完成应只含完成事项")

        var prefixedEvent = MatterEvent(
            id: UUID(),
            title: "帮助入口移除",
            detail: "gf 帮助入口移除已合入 main，但线上仍是旧版本：帮助入口移除相关改动已完成，当前尚未部署生产环境。",
            recordedAt: now,
            status: .progressed,
            evidenceIDs: [UUID()]
        )
        prefixedEvent.headline = "gf 帮助入口移除已合入 main，但线上仍是旧版本"
        let timelineNode = TopicTimelineEntry(event: prefixedEvent)
        try expect(timelineNode.headline == "gf 帮助入口移除已合入 main，但线上仍是旧版本", "时间轴节点标题提取错误")
        try expect(timelineNode.body == "帮助入口移除相关改动已完成，当前尚未部署生产环境。", "时间轴节点正文未剥离重复标题前缀")

        try expect(TopicListPresentation.relativeTime(now, now: now, calendar: calendar) == "今天", "相对时间：今天")
        try expect(TopicListPresentation.relativeTime(calendar.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: calendar) == "昨天", "相对时间：昨天")
        try expect(TopicListPresentation.relativeTime(calendar.date(byAdding: .day, value: -3, to: now)!, now: now, calendar: calendar) == "3 天前", "相对时间：N 天前")

        try verifyTodayPriorityAndSeparation(now: now, calendar: calendar)
        try verifyTopicReadingAnchorsAndAdaptiveFolding(now: now, calendar: calendar)

        print("PASS: topic list presentation, Today urgency ordering/separation, and TopicReading date anchors/adaptive folding")
    }

    private static func verifyTodayPriorityAndSeparation(now: Date, calendar: Calendar) throws {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!

        var webProof = CaptureRecord(
            eventTemplate: .manualMoment,
            createdAt: twoDaysAgo,
            sourceAppName: "Browser",
            sourceBundleIdentifier: "example.browser",
            windowTitle: "Cedar PR",
            contentHash: "cedar-1",
            ocrText: "Cedar 群组校验上限规则受阻",
            textOrigin: .userInput
        )
        webProof.pageURL = "https://code.example.invalid/pr/42"

        let plainProof = CaptureRecord(
            eventTemplate: .manualMoment,
            createdAt: yesterday,
            sourceAppName: "Terminal",
            sourceBundleIdentifier: "example.term",
            windowTitle: "Nova",
            contentHash: "nova-1",
            ocrText: "Nova 图表边界 PR #108 已合入",
            textOrigin: .userInput
        )

        let nextStepNote = ManualMatterNote(
            title: "Atlas 问答改造",
            detail: "昨天已完成改造提交，界面交互待核验。",
            status: .pending,
            eventAt: threeDaysAgo,
            nextAction: "验收 Atlas 问答的新界面"
        )
        let nextStepCapture = try nextStepNote.capture(recordedAt: threeDaysAgo)

        func summaryItem(_ title: String, _ detail: String, status: String, topic: String, sourceID: UUID, section: DailySummarySection = .progress) -> DailySummaryItem {
            DailySummaryItem(
                section: section,
                title: title,
                detail: detail,
                evidenceIDs: [sourceID],
                knowledge: DailyItemKnowledge(topic: topic, kind: .matter, status: status, ownedByUser: true, quotes: [])
            )
        }

        let dueReminder = ReminderCandidate(
            title: "提交本周里程碑同步",
            detail: "下午两点前发出",
            dueAt: now.addingTimeInterval(-600),
            sourceCaptureIDs: [plainProof.id],
            confidence: 1,
            status: .scheduled
        )

        var state = RecallState(
            captures: [webProof, plainProof, nextStepCapture],
            reminders: [dueReminder],
            dailySummaries: [
                DailySummary(
                    day: twoDaysAgo,
                    content: "",
                    sourceCaptureIDs: [webProof.id],
                    todos: [],
                    generationKind: .cloud,
                    items: [
                        summaryItem("等待确认伙伴选择上限规则", "后端接口契约尚未对齐，推进卡住。", status: "blocked", topic: "Cedar 群组校验", sourceID: webProof.id),
                        summaryItem("开始阅读第三章", "整理了前两节摘要。", status: "pending", topic: "每周阅读笔记", sourceID: webProof.id)
                    ]
                ),
                DailySummary(
                    day: yesterday,
                    content: "",
                    sourceCaptureIDs: [plainProof.id],
                    todos: [],
                    generationKind: .cloud,
                    items: [
                        summaryItem("PR #108 已完成边界用例核对", "单测通过，继续收尾。", status: "progressed", topic: "Nova 图表边界", sourceID: plainProof.id),
                        summaryItem("发版开关清理已合入主干", "等待运维批次发布上线。", status: "waiting", topic: "Atlas 发版开关清理", sourceID: plainProof.id),
                        DailySummaryItem(section: .insights, title: "下午编码更集中", detail: "单纯观察现象不应进入接着干", evidenceIDs: [plainProof.id],
                                         knowledge: DailyItemKnowledge(topic: "节奏观察", kind: .matter, status: "pending", ownedByUser: true, quotes: []))
                    ]
                )
            ]
        )

        // Add an unreviewed day record? Note yesterday already has a review; verify strict 5-tier priority first.
        let matters = MatterMemoryEngine().files(in: state, calendar: calendar)
        let brief = LocalBriefing.todayBrief(in: state, matters: matters, now: now, calendar: calendar, matterLimit: 10)
        try expect(brief.actionItems.count == 5, "应包含 1 条留话下一步 + 1 条到期提醒 + 3 条未闭环事项（过滤掉 waiting 与 insights）")
        try expect(brief.actionItems[0].hasUserNextStep && brief.actionItems[0].nextAction == "验收 Atlas 问答的新界面",
                   "本人明确留下的下一步必须排在第一位（即使记录于 3 天前）")
        try expect(brief.actionItems[1].kind == .dueReminder && brief.actionItems[1].title == "提交本周里程碑同步",
                   "到期提醒应排在第二优先级")
        try expect(brief.actionItems[2].status == .blocked && brief.actionItems[2].topicTitle == "Cedar 群组校验",
                   "2 天前卡住了的事项必须排在昨天普通推进中事项前面")
        try expect(brief.actionItems[2].savedPageURL == "https://code.example.invalid/pr/42",
                   "有本地已保存网页地址时应透出 savedPageURL")
        try expect(brief.actionItems[3].status == .pending && brief.actionItems[3].topicTitle == "每周阅读笔记",
                   "还没做应排在推进中之前")
        try expect(brief.actionItems[4].status == .progressed && brief.actionItems[4].topicTitle == "Nova 图表边界",
                   "推进中应排在最后")
        try expect(brief.actionItems[4].savedPageURL == nil && brief.actionItems[4].referenceToken == "PR #108",
                   "无网页地址但含 PR 编号时应提取本地编号供复制，且不伪造 URL")
        try expect(brief.waitingItems.count == 1 && brief.waitingItems[0].topicTitle == "Atlas 发版开关清理",
                   "等待外部结果的事项应剥离到 waitingItems 独立区")

        // Verify missing review is separated to missingReview (and placed at the end of resume(), never above open matters).
        state.dailySummaries.removeAll { calendar.isDate($0.day, inSameDayAs: yesterday) }
        let briefWithMissing = LocalBriefing.todayBrief(in: state, matters: matters, now: now, calendar: calendar)
        try expect(briefWithMissing.missingReview?.recordCount == 1 && briefWithMissing.missingReview?.title.contains("1 条记录") == true,
                   "缺一天回顾应单独输出当日记录条数")
        try expect(!briefWithMissing.actionItems.contains { $0.kind == .missingReview },
                   "缺一天回顾不应混入动手队列 actionItems")
        let legacyResume = LocalBriefing.resume(in: state, matters: matters, now: now, calendar: calendar)
        try expect(legacyResume.last?.kind == .missingReview && legacyResume.first?.kind != .missingReview,
                   "resume() 中缺回顾提示应沉到底部而非压在待办前面")
    }

    private static func verifyTopicReadingAnchorsAndAdaptiveFolding(now: Date, calendar: Calendar) throws {
        func makeEvent(daysAgo: Int, headline: String, detail: String, status: WorkEpisodeStatus = .progressed, next: String? = nil) -> MatterEvent {
            let d = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            var e = MatterEvent(id: UUID(), title: "Atlas 发版开关清理", detail: detail, recordedAt: d, eventAt: d, status: status, evidenceIDs: [UUID()], nextAction: next)
            e.headline = headline
            return e
        }

        // 2 events, no cross-day summary, no explicit nextAction -> openNextAction must stay nil ("无据留白") and history stays expanded (<= 3).
        let twoEvents = MatterFile(
            id: "topic:atlas-flag",
            title: "Atlas 发版开关清理",
            events: [
                makeEvent(daysAgo: 4, headline: "提交清理 PR", detail: "提交清理 PR：完成代码删除并提测"),
                makeEvent(daysAgo: 1, headline: "PR 已合入主干", detail: "PR 已合入主干：当时生产环境仍运行旧版本")
            ]
        )
        let readingTwo = TopicReading(file: twoEvents)
        try expect(!readingTwo.collapsesHistoryByDefault, "无跨日小结且记录 ≤ 3 条时不应默认折叠历史")
        try expect(readingTwo.openNextAction == nil, "无明确下一步依据时必须留白，不能编造套话")
        try expect(readingTwo.lastConfirmedAnchor(now: now, calendar: calendar).contains("最后确认"), "现在段落必须包含最后确认日期锚点")
        try expect(!readingTwo.currentStatusSummary.hasPrefix("PR 已合入主干：PR 已合入主干"), "现在段落正文不应重复拼接标题前缀")

        // 4 events -> collapsesHistoryByDefault becomes true; explicit nextAction -> surfaced with provenance.
        let fourEvents = MatterFile(
            id: "topic:atlas-flag",
            title: "Atlas 发版开关清理",
            events: [
                makeEvent(daysAgo: 6, headline: "梳理开关依赖", detail: "盘点旧开关引用"),
                makeEvent(daysAgo: 4, headline: "提交清理 PR", detail: "完成代码移除"),
                makeEvent(daysAgo: 2, headline: "通过代码评审", detail: "合入主分支"),
                makeEvent(daysAgo: 1, headline: "等待核对线上版本", detail: "下一步：确认生产环境部署结果", status: .pending)
            ]
        )
        let readingFour = TopicReading(file: fourEvents)
        try expect(readingFour.collapsesHistoryByDefault, "记录超过 3 条时应默认折叠更早记录")
        try expect(readingFour.openNextAction == "确认生产环境部署结果", "记录中明确写出的下一步应被准确提取")
    }
}
