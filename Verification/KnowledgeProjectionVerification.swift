import Foundation
import RecallKit

enum KnowledgeProjectionVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(errorDescription: message) }
    }
    static func capture(_ text: String, at date: Date, title: String, origin: CaptureTextOrigin = .screenOCR) -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, createdAt: date, sourceAppName: "合成记录",
            sourceBundleIdentifier: "test.knowledge", windowTitle: title, contentHash: UUID().uuidString,
            ocrText: text, textOrigin: origin)
    }
    static func review(day: Date, evidence: [UUID], topic: String, quotes: [DailyLedgerQuote], owned: Bool = true) -> DailySummary {
        let knowledge = DailyItemKnowledge(topic: topic, kind: .matter, status: "completed", ownedByUser: owned,
            quotes: quotes.map(\.text), category: "work")
        let item = DailySummaryItem(section: .progress, title: "完成了\(topic)这一项", detail: "结果已经核对，限制也保留了下来。",
            evidenceIDs: evidence, knowledge: knowledge)
        var summary = DailySummary(day: day, content: "", sourceCaptureIDs: evidence, todos: [], generationKind: .cloud, items: [item])
        summary.ledger = [DailyMatterLedgerEntry(topic: topic, kind: .matter, status: "completed", section: "progress",
            title: item.title, detail: item.detail, ownedByUser: owned, quotes: quotes, evidenceIDs: evidence, occurredAt: quotes.flatMap(\.sourceIDs).isEmpty ? day : nil)]
        return summary
    }
    static func run() throws {
        try partialDaysStayInTopics()
        try deletingOneScreenshotKeepsTheMatter()
        try onlyUserQuoteRemovedBecomesAClue()
        try unknownSpeakerIsNotTheUser()
        try ledgerFeedsTopicsAndSortsByCaptureTime()
        try activationNeedsMoreThanOneDurableSentence()
        try periodNamesMissingDays()
        try discoveryStartsAtFourteenDays()
        try interfaceKeysAreTranslated()
        try currentLedgerRetrievalSkipsReencoding()
        try askSearchSkipsRepeatedArchiveWalks()
        print("PASS: knowledge projection keeps partial days, surviving evidence, unknown speakers, the matter ledger and the shorter discovery window")
    }
    static func partialDaysStayInTopics() throws {
        let day = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(-86_400 * 2))
        let later = day.addingTimeInterval(86_400)
        let shot = capture("[聊天·自己] 账单导出已核对分页边界。", at: day, title: "账单导出")
        let summary = review(day: day, evidence: [shot.id], topic: "账单导出", quotes: [DailyLedgerQuote(text: "账单导出已核对分页边界。", sourceIDs: [shot.id], speaker: "user")])
        let note = ManualMatterNote(title: "木刻练习", detail: "完成了第一张，还没开始第二张。", status: .progressed, eventAt: later.addingTimeInterval(60))
        let manual = try note.capture(recordedAt: later.addingTimeInterval(120))
        let state = RecallState(captures: [shot, manual], dailySummaries: [summary])
        let titles = Set(MatterMemoryEngine().files(in: state).map(\.title))
        try expect(titles.contains("账单导出") && titles.contains("木刻练习"), "没有回顾的日子和手写补充都应留在主题里")
        let sameDay = try ManualMatterNote(title: "账单导出", detail: "账单导出已核对分页边界。", status: .completed, eventAt: day.addingTimeInterval(30)).capture(recordedAt: day.addingTimeInterval(90))
        let duplicated = RecallState(captures: [shot, sameDay], dailySummaries: [summary])
        let export = MatterMemoryEngine().files(in: duplicated).first { $0.title == "账单导出" }
        try expect(export?.events.count == 1, "同一主题在同一天不应被回顾和手写各计一次")
    }
    static func deletingOneScreenshotKeepsTheMatter() throws {
        let day = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(-86_400))
        let first = capture("第一张截图写了账单导出已经完成。", at: day.addingTimeInterval(10), title: "账单导出")
        let second = capture("第二张截图仍写着账单导出已经完成。", at: day.addingTimeInterval(40), title: "账单导出")
        let quotes = [DailyLedgerQuote(text: "账单导出已经完成", sourceIDs: [first.id, second.id], speaker: "user")]
        let summary = review(day: day, evidence: [first.id, second.id], topic: "账单导出", quotes: quotes)
        for removed in [first, second] {
            let kept = removed.id == first.id ? second : first
            let state = RecallState(captures: [kept], dailySummaries: [summary])
            let file = MatterMemoryEngine().files(in: state).first { $0.title == "账单导出" }
            try expect(file?.evidenceIDs == [kept.id], "删掉任意一张截图后，剩下的依据仍应撑住这条主题")
        }
    }
    static func onlyUserQuoteRemovedBecomesAClue() throws {
        let day = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(-86_400))
        let mine = capture("[聊天·自己] 我来完成账单导出。", at: day.addingTimeInterval(10), title: "账单导出")
        let other = capture("分页边界已经列在文档里。", at: day.addingTimeInterval(40), title: "账单导出")
        let quotes = [
            DailyLedgerQuote(text: "我来完成账单导出。", sourceIDs: [mine.id], speaker: "user"),
            DailyLedgerQuote(text: "分页边界已经列在文档里。", sourceIDs: [other.id], speaker: "unknown")
        ]
        let summary = review(day: day, evidence: [mine.id, other.id], topic: "账单导出", quotes: quotes)
        let state = RecallState(captures: [other], dailySummaries: [summary])
        try expect(!MatterMemoryEngine().files(in: state).contains { $0.title == "账单导出" }, "唯一的本人原话被去掉后，不应再当作本人事项")
        try expect(DailyKnowledgeEngine().referenceFiles(in: state).contains { $0.title == "账单导出" }, "剩下的依据应降为线索")
    }
    static func unknownSpeakerIsNotTheUser() throws {
        try expect(!DirectDailyReviewEngine.countsAsUser(speakers: [.unknown, .unknown]), "说话人全是未知时，不能因为模型标成本人就生效")
        try expect(DirectDailyReviewEngine.countsAsUser(speakers: [.unknown, .user]), "至少一条本人且不是资料的原话才算本人")
        try expect(!DirectDailyReviewEngine.countsAsUser(speakers: [.user], references: [true]), "引用资料里的本人标记不能算本人原话")
    }
    static func ledgerFeedsTopicsAndSortsByCaptureTime() throws {
        let day = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(-86_400))
        let early = capture("早上先改了发布页。", at: day.addingTimeInterval(8 * 3600), title: "发布页")
        let late = capture("下午又改了账单导出。", at: day.addingTimeInterval(15 * 3600), title: "账单导出")
        var summary = review(day: day, evidence: [late.id], topic: "账单导出", quotes: [DailyLedgerQuote(text: "下午又改了账单导出。", sourceIDs: [late.id], speaker: "user")])
        summary.ledger.append(DailyMatterLedgerEntry(topic: "发布页改版", kind: .matter, status: "completed", section: "progress",
            title: "完成了发布页改版这一项", detail: "早上的布局调整已经核对。", ownedByUser: true,
            quotes: [DailyLedgerQuote(text: "早上先改了发布页。", sourceIDs: [early.id], speaker: "user")],
            evidenceIDs: [early.id], occurredAt: early.createdAt))
        summary.items = Array(summary.items.prefix(1))
        let files = MatterMemoryEngine().files(in: RecallState(captures: [early, late], dailySummaries: [summary]))
        try expect(Set(files.map(\.title)) == ["账单导出", "发布页改版"], "主题应读取事项列表，而不是只看精选的一条")
        let release = files.first { $0.title == "发布页改版" }
        try expect(release?.events.first?.eventAt == early.createdAt, "发生时间应取依据里最早的截图时间")
    }
    static func activationNeedsMoreThanOneDurableSentence() throws {
        let now = Date.now
        let once = capture("[聊天·角色未知] 我一直喜欢蓝色封面。", at: now.addingTimeInterval(-3600), title: "封面讨论")
        let unknown = MemoryKnowledgeEngine().reconcile(RecallState(captures: [once]), force: true, now: now)
        try expect(!unknown.claims.contains { $0.kind == .preference && $0.usable(at: now) }, "未知说话人说一次“一直”不能生效")
        let person = capture("[聊天·自己] 林晓是我的同事。", at: now.addingTimeInterval(-7200), title: "同事")
        let people = MemoryKnowledgeEngine().reconcile(RecallState(captures: [person]), force: true, now: now)
        try expect(!people.claims.contains { $0.kind == .person && $0.usable(at: now) }, "人物不能只出现一天就生效")
        let spoken = capture("[聊天·自己] 我一直喜欢蓝色封面。", at: now.addingTimeInterval(-1800), title: "封面讨论")
        let durable = MemoryKnowledgeEngine().reconcile(RecallState(captures: [spoken]), force: true, now: now)
        try expect(durable.claims.contains { $0.kind == .preference && $0.usable(at: now) }, "本人原话里的持续说法可以把天数要求降到一天")
    }
    static func periodNamesMissingDays() throws {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let reviewed = start
        let missing = calendar.date(byAdding: .day, value: 1, to: start)!
        let shot = capture("周一的记录。", at: reviewed.addingTimeInterval(3600), title: "记录")
        let later = capture("周二的记录还没有回顾。", at: missing.addingTimeInterval(3600), title: "记录")
        let summary = review(day: reviewed, evidence: [shot.id], topic: "周记", quotes: [DailyLedgerQuote(text: "周一的记录。", sourceIDs: [shot.id], speaker: "user")])
        let period = ReviewPeriod(start: start, end: calendar.date(byAdding: .day, value: 7, to: start)!)
        let gaps = PeriodReviewFromDaily.gaps(in: RecallState(captures: [shot, later], dailySummaries: [summary]), period: period, now: period.end.addingTimeInterval(-60))
        try expect(gaps.headline.contains("本周") && gaps.headline.contains("未生成") && gaps.missingRecordedDays == [missing], "周期回顾应标出有记录但没生成回顾的日子")
    }
    static func discoveryStartsAtFourteenDays() throws {
        let now = Date.now
        let recent = capture("[聊天·自己] 我会整理验收清单", at: now.addingTimeInterval(-86_400), title: "合成会话")
        let older = capture("[聊天·自己] 我会整理更早的验收清单", at: now.addingTimeInterval(-20 * 86_400), title: "合成会话")
        var state = RecallState(captures: [recent, older], privacy: PrivacySettings(cloudUseEnabled: true))
        state.rules = state.rules.map { var rule = $0; rule.participatesInReminders = true; return rule }
        let plan = ModelReminderDiscovery().plan(in: state, force: true, now: now)
        let ids = Set(plan.groups.flatMap { $0.map(\.id) })
        try expect(ids.contains(recent.id) && !ids.contains(older.id) && plan.earlierEligibleCount >= 1 && plan.horizonDays == 14, "第一次发现待办只扫最近 14 天，并留下更早的记录")
    }
    static func currentLedgerRetrievalSkipsReencoding() throws {
        let now = Date.now
        var state = RecallState(captures: (0..<400).map { index in
            CaptureRecord(eventTemplate: .workCheckpoint, createdAt: now.addingTimeInterval(-Double(index) * 3_600),
                sourceAppName: "合成", sourceBundleIdentifier: "example.synthetic", windowTitle: "账单导出", contentHash: "hash-\(index)",
                ocrText: String(repeating: "账单导出的分页边界已经核对。\(index) ", count: 120), textOrigin: .screenOCR)
        })
        let stamp = MemoryKnowledgeEngine.inputStamp(for: state)
        try expect(stamp == MemoryKnowledgeEngine.inputStamp(for: state), "同样的记录应得到稳定的账本戳")
        state.captures[0].contentHash += "-edited"
        try expect(MemoryKnowledgeEngine.inputStamp(for: state) != stamp, "记录变化后账本戳应失效")
        state.captures[0].contentHash = "hash-0"
        state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state, force: true)
        try expect(state.memoryKnowledge.ledgerInputStamp == MemoryKnowledgeEngine.inputStamp(for: state), "整理后的账本戳应与当前记录一致")
        let clock = ContinuousClock()
        let started = clock.now
        let plan = MemoryRetrievalEngine().plan(question: "账单导出后来怎样了", state: state, fallback: [], trustLedger: true, alreadyCorrected: true)
        let elapsed = started.duration(to: clock.now)
        try expect(elapsed < .milliseconds(500), "账本检索不应在过滤和排序时反复扫描相同条目的全文")
        print("PERF: current-ledger retrieval 400 long records \(elapsed)")
        try expect(plan.evidence.contains { $0.ocrText.contains("账单导出") }, "跳过整库对账后仍应取回相关记录")
    }
    static func askSearchSkipsRepeatedArchiveWalks() throws {
        let now = Date.now
        let captures = (0..<800).map { index in
            capture(String(repeating: "分页边界 \(index) ", count: 30), at: now.addingTimeInterval(-Double(index) * 60), title: "其他窗口")
        }
        var summary = review(day: now, evidence: [captures[0].id], topic: "账单导出", quotes: [
            DailyLedgerQuote(text: "账单导出已核对分页边界。", sourceIDs: [captures[0].id], speaker: "user")
        ])
        summary.ledger += (0..<160).map { index in
            DailyMatterLedgerEntry(topic: "其他事项\(index)", kind: .matter, status: "progressed", section: "progress",
                title: "其他事项\(index)", detail: "细节", ownedByUser: true, quotes: [], evidenceIDs: [captures[0].id], occurredAt: now)
        }
        let state = RecallState(captures: captures, dailySummaries: [summary])
        let clock = ContinuousClock()
        let started = clock.now
        let topics = DailyKnowledgeEngine().topics(matching: "账单导出后来怎样了", in: state, alreadyCorrected: true)
        try expect(started.duration(to: clock.now) < .milliseconds(400), "按主题找记录不应为每一行重建全部截图索引")
        try expect(topics.contains { $0.title == "账单导出" }, "大量账本行里仍应命中被问到的主题")
        let typed = capture("Run Brew Cleanup now", at: now, title: "终端")
        let found = MemorySearchEngine().search(MemorySearchQuery(text: "brew cleanup"), in: captures + [typed], limit: 5)
        try expect(found.contains { $0.capture.id == typed.id }, "大小写不同的关键词仍应命中")
    }
    static func interfaceKeysAreTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = ["Sources/RecallApp", "Sources/RecallKit"].flatMap { relative -> [String] in
            let directory = root.appendingPathComponent(relative)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
            return enumerator.compactMap { item -> String? in
                guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }
        }
        let pattern = #"RecallLocalization\.text\("([^"\\]+)"\)"#
        let expression = try NSRegularExpression(pattern: pattern)
        var keys: Set<String> = []
        for source in sources {
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[keyRange]))
            }
        }
        let missing = RecallLocalization.missingEnglishKeys(Array(keys))
        try expect(missing.isEmpty, "界面中文缺少英文翻译：" + missing.prefix(12).joined(separator: "、"))
    }
}
