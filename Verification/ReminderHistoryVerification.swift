import Foundation
import RecallKit

enum ReminderHistoryVerification {
    private static let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-history-verification-" + UUID().uuidString)
    static let now = Date(timeIntervalSince1970: 1_793_361_600)
    static func run() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try legacyDates()
        try grouping()
        try filtersAndPagination()
        try await restoration()
        try await cleanup()
        try await sourcePreferences()
        try await concurrentDiscovery()
        try closedOccurrenceStability()
        try await rollback()
        try await missingSources()
        print("PASS: 10 reminder-history scenarios (legacy dates, exact grouping, full-history filters, restoration, scoped cleanup, source preferences, scan races, stable closures, rollback and source deletion)")
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func capture(_ name: String = "Synthetic Chat", bundle: String = "example.chat") -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, createdAt: now.addingTimeInterval(-86_400), sourceAppName: name,
                      sourceBundleIdentifier: bundle, contentHash: UUID().uuidString, ocrText: "[聊天·自己] 待办：明天提交 Atlas 验收报告", textOrigin: .userInput)
    }
    private static func item(_ title: String = "提交 Atlas 验收报告", status: ReminderStatus = .dismissed, source: CaptureRecord? = nil, at: Date = now) -> ReminderCandidate {
        ReminderCandidate(title: title, detail: "从合成记录识别；创建前请确认。", sourceCaptureIDs: source.map { [$0.id] } ?? [], confidence: 0.9,
            status: status, createdAt: at.addingTimeInterval(-3_600), updatedAt: at, origin: source == nil ? .manual : .discovered,
            completedAt: status == .completed ? at : nil, dismissedUntil: status == .dismissed ? at.addingTimeInterval(30 * 86_400) : nil)
    }
    private static func storage(_ state: RecallState) throws -> RecallStorage {
        let storage = try RecallStorage(rootURL: root.appendingPathComponent(UUID().uuidString))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: storage.stateURL)
        return storage
    }
    private static func store(_ state: RecallState) throws -> FileMemoryStore { try FileMemoryStore(storage: storage(state)) }
    private static func legacyDates() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var old = item(status: .cancelled); old.completedAt = now.addingTimeInterval(-86_400)
        var json = try JSONSerialization.jsonObject(with: encoder.encode(old)) as! [String: Any]
        json.removeValue(forKey: "closedAt")
        let restored = try decoder.decode(ReminderCandidate.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(restored.closedAt == now, "取消时间错误使用了上一次重复提醒的完成时间")
        let profile = try decoder.decode(ReminderLearningProfile.self, from: Data(#"{"semanticFeedback":{},"preferredHourHistogram":{}}"#.utf8))
        try expect(profile.disabledReminderApplications.isEmpty && profile.clearedHistory == nil, "旧设置不能兼容读取")
        var changed = restored; changed.updatedAt = now.addingTimeInterval(5 * 86_400)
        try expect(ReminderHistoryRow.date(of: changed) == now, "重验改变了终态处理日期")
    }
    private static func grouping() throws {
        let a = capture(), b = capture("Synthetic Browser", bundle: "example.browser")
        let first = item("**提交 Atlas 验收报告**", source: a)
        let second = item("提交 Atlas 验收报告", source: a, at: now.addingTimeInterval(-60))
        let differentStatus = item(status: .completed, source: a)
        let otherApp = item(source: b)
        let yesterday = item(source: a, at: now.addingTimeInterval(-86_400))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 28_800)!
        let rows = ReminderHistoryIndex(reminders: [first, second, differentStatus, otherApp, yesterday], captures: [a, b]).rows(calendar: calendar)
        try expect(rows.count == 4 && rows.first(where: { $0.reminders.count == 2 })?.reminderIDs == [first.id, second.id], "重复分组越过日期、状态或来源边界")
        let days = ReminderHistoryIndex.days(for: rows)
        try expect(days.count == 2 && days.reduce(0) { $0 + $1.recordCount } == 5, "日期组计数丢失了重复项")
        try expect(days[0].title(now: now, calendar: calendar).hasPrefix("今天") && days[1].title(now: now, calendar: calendar).hasPrefix("昨天"), "本地日期分组错误")
    }
    private static func filtersAndPagination() throws {
        let a = capture(), b = capture("Synthetic Browser", bundle: "example.browser")
        let items = (0..<203).map { index in item("核对 Atlas 边界 \(index)", status: index % 5 == 0 ? .completed : .dismissed, source: index % 2 == 0 ? a : b, at: now.addingTimeInterval(-Double(index * 60))) }
        let index = ReminderHistoryIndex(reminders: items, captures: [a, b])
        try expect(index.matching().count == 203 && index.rows().count == 203, "历史记录被旧页面条数限制截断")
        let selected = index.rows(search: "Atlas 202", sourceID: ReminderSourceChoice(capture: a)!.id)
        try expect(selected.count == 1 && selected[0].title.hasSuffix("202"), "筛选只搜索了当前页")
        try expect(index.rows(filter: .completed).count == 41 && index.rows(filter: .dismissedAndCancelled).count == 162, "状态数字和数据范围不一致")
        let page = Array(index.rows().dropFirst(200).prefix(20))
        try expect(page.count == 3 && Set(page.flatMap(\.reminderIDs)).count == 3, "最后一页不可达或遗漏记录")
        try expect(index.rows(search: "不存在的内容").isEmpty, "搜索没有正确返回空状态")
    }
    private static func restoration() async throws {
        let source = capture(), old = item(source: capture())
        var dismissed = old; dismissed.sourceCaptureIDs = [source.id]; dismissed.dueAt = now.addingTimeInterval(-60)
        let complete = item("整理 Nova 方案", status: .completed, source: source), scheduled = item("保留已安排提醒", status: .scheduled)
        let storage = try storage(RecallState(captures: [source], reminders: [dismissed, complete, scheduled]))
        let store = try FileMemoryStore(storage: storage)
        let count = try await store.restoreReminderHistory(ids: [dismissed.id, complete.id, scheduled.id], now: now)
        let state = await store.snapshot()
        try expect(count == 2 && state.reminders.filter { $0.status == .proposed }.count == 2, "恢复没有准确限制为历史记录")
        try expect(state.reminders.first { $0.id == dismissed.id }?.dueAt == nil && state.reminders.first { $0.id == dismissed.id }?.closedAt == nil, "恢复保留了过去的通知时间或终态时间")
        try expect(state.reminders.first { $0.id == scheduled.id }?.status == .scheduled && state.captures.count == 1, "恢复误改了通知状态或原始记录")
        let reopened = try FileMemoryStore(storage: storage)
        let snapshot = await reopened.snapshot()
        try expect(snapshot.reminders.filter { $0.status == .proposed }.count == 2, "重启后恢复状态丢失")
    }
    private static func cleanup() async throws {
        let source = capture(), ignored = item(source: capture()), completed = item("已完成合成事项", status: .completed)
        var linked = ignored; linked.sourceCaptureIDs = [source.id]
        let scheduled = item("已安排合成事项", status: .scheduled)
        let store = try store(RecallState(captures: [source], reminders: [linked, completed, scheduled]))
        let count = try await store.removeReminderHistory(ids: [linked.id, completed.id, scheduled.id], onlyDismissed: true, now: now)
        let state = await store.snapshot()
        try expect(count == 1 && state.reminders.count == 2 && state.captures.count == 1, "批量清理误删了完成、待处理或原始记忆")
        try expect(state.reminderLearningProfile.suppressesHistory(linked, now: now.addingTimeInterval(60)), "清理后丢失了忽略期")
        let data = try JSONEncoder().encode(state.reminderLearningProfile.clearedHistory)
        try expect(!String(decoding: data, as: UTF8.self).contains(linked.title), "已清理的历史正文仍保留在规则中")
        _ = try await store.deleteCapture(id: source.id)
        let deleted = await store.snapshot()
        try expect(deleted.reminderLearningProfile.clearedHistory?.isEmpty == true, "来源删除后仍残留关联历史指纹")
    }
    private static func sourcePreferences() async throws {
        let a = capture(), b = capture("Synthetic Browser", bundle: "example.browser")
        let pending = item(status: .proposed, source: a)
        let checkpoint = ReminderDiscoveryCheckpoint(processedCaptureHashes: [a.id.uuidString: "a", b.id.uuidString: "b"])
        let store = try store(RecallState(captures: [a, b], reminders: [pending], reminderDiscoveryCheckpoint: checkpoint))
        let source = ReminderSourceChoice(capture: a)!
        try await store.setReminderApplication(source, disabled: true)
        var state = await store.snapshot()
        try expect(!state.reminderLearningProfile.permitsReminderDiscovery(from: a) && state.reminderLearningProfile.permitsReminderDiscovery(from: b), "来源开关影响了其他应用")
        try expect(state.reminders == [pending] && state.privacy == PrivacySettings(), "停止识别误改了已有提醒或采集设置")
        let found = ReminderExtractor().candidates(from: [a], existing: [], now: now, learningProfile: state.reminderLearningProfile)
        try expect(found.isEmpty, "停用来源仍然生成候选")
        try await store.setReminderApplication(source, disabled: false)
        state = await store.snapshot()
        try expect(state.reminderLearningProfile.permitsReminderDiscovery(from: a) && state.reminderDiscoveryCheckpoint.processedCaptureHashes[a.id.uuidString] == nil && state.reminderDiscoveryCheckpoint.processedCaptureHashes[b.id.uuidString] == "b", "恢复来源没有重新允许增量检查，或清除了其他来源的检查点")
    }
    private static func concurrentDiscovery() async throws {
        let source = capture(), ignored = item(source: capture())
        var old = ignored; old.sourceCaptureIDs = [source.id]
        let store = try store(RecallState(captures: [source], reminders: [old]))
        let checkpoint = ReminderDiscoveryCheckpoint(processedCaptureHashes: [source.id.uuidString: MemoryKnowledgeEngine.version(of: source)])
        _ = try await store.restoreReminderHistory(ids: [old.id], now: now.addingTimeInterval(5))
        _ = try await store.applyReminderDiscovery(candidates: [], checkpoint: checkpoint, revalidatedSourceIDs: [source.id], startedAt: now, now: now.addingTimeInterval(10))
        var state = await store.snapshot()
        try expect(state.reminders.first?.status == .proposed, "迟到的重验移除了刚恢复的事项")
        try await store.replaceReminders([old])
        _ = try await store.removeReminderHistory(ids: [old.id], now: now)
        var stale = old; stale.id = UUID(); stale.status = .proposed
        let added = try await store.applyReminderDiscovery(candidates: [stale], checkpoint: checkpoint, revalidatedSourceIDs: [source.id], startedAt: now, now: now.addingTimeInterval(10))
        state = await store.snapshot()
        try expect(added == 0 && state.reminders.isEmpty, "迟到的发现重新插入了已清理的忽略项")
        try await store.setReminderApplication(ReminderSourceChoice(capture: source)!, disabled: true)
        stale.title = "另一个合成待办"
        _ = try await store.applyReminderDiscovery(candidates: [stale], checkpoint: checkpoint, revalidatedSourceIDs: [source.id], startedAt: now, now: now.addingTimeInterval(10))
        state = await store.snapshot()
        try expect(state.reminders.isEmpty, "迟到的扫描绕过了来源停用")
    }
    private static func closedOccurrenceStability() throws {
        let old = item(source: capture(), at: now.addingTimeInterval(-31 * 86_400))
        var next = old; next.status = .proposed; next.id = UUID(); next.updatedAt = now; next.closedAt = nil
        let result = ReminderExtractor().merging([next], into: [old], now: now)
        try expect(result.count == 2 && result.contains { $0.id == old.id && $0.status == .dismissed && $0.closedAt == old.closedAt }, "重新发现覆盖了旧历史或处理日期")
        try expect(result.first?.status == .proposed && Set(result.map(\.id)).count == 2, "新一次事项没有作为独立候选进入待确认")
    }
    private static func rollback() async throws {
        let source = capture(), old = item(source: capture())
        var linked = old; linked.sourceCaptureIDs = [source.id]
        let storage = try storage(RecallState(captures: [source], reminders: [linked]))
        let store = try FileMemoryStore(storage: storage)
        let backup = storage.stateURL.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: storage.stateURL, withIntermediateDirectories: false)
        do { _ = try await store.removeReminderHistory(ids: [linked.id], now: now); throw Failure(message: "未触发合成写入失败") }
        catch is Failure { throw Failure(message: "写入失败未被传播") }
        catch {}
        let state = await store.snapshot()
        try expect(state.reminders == [linked] && state.reminderLearningProfile.clearedHistory == nil, "失败写入没有回滚历史和指纹")
        try FileManager.default.removeItem(at: storage.stateURL)
        try FileManager.default.moveItem(at: backup, to: storage.stateURL)
    }
    private static func missingSources() async throws {
        let old = item(source: capture()), manual = item("手动历史记录")
        let store = try store(RecallState(reminders: [old, manual]))
        do { _ = try await store.restoreReminderHistory(ids: [old.id], now: now); throw Failure(message: "无来源的派生提醒仍被恢复") }
        catch ReminderHistoryError.unavailableSource {}
        let count = try await store.restoreReminderHistory(ids: [manual.id], now: now)
        try expect(count == 1, "手动提醒错误要求了采集来源")
    }
}
