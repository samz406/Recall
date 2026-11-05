import Foundation
import RecallKit

enum ReviewScheduleSaveVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func run() async throws {
        try await largeArchive()
        try await lifecycle()
        try await rollbackAndNoop()
        print("PASS: 3 schedule-save suites (6351-record fast path, no archive maintenance, restart/next trigger, pause/delete, rollback and unchanged saves)")
    }
    private static func largeArchive() async throws {
        let f = try StartupLoadingVerification.fixture(count: 6_351)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let store = try verificationStore(storage: f.storage, deferMaintenance: true)
        let before = await store.snapshot()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let originalKnowledge = try encoder.encode(before.memoryKnowledge)
        _ = await store.preparedForChat()
        let plan = ReviewSchedule(template: ReviewTemplate(kind: .personal))
        let clock = ContinuousClock(), start = clock.now
        try await store.saveReviewSchedule(plan)
        let elapsed = start.duration(to: clock.now)
        let after = await store.snapshot(), dirty = await store.memoryIndexNeedsRebuild()
        let savedKnowledge = try encoder.encode(after.memoryKnowledge)
        try expect(elapsed < .seconds(2), "保存计划不应在数千条记录上执行整库整理")
        try expect(after.captures == before.captures && after.dailySummaries == before.dailySummaries
            && savedKnowledge == originalKnowledge && after.episodes == before.episodes
            && after.understandingJobs == before.understandingJobs && after.summaryFeedback == before.summaryFeedback
            && dirty, "保存计划改写了记忆、回顾或后台队列，或重建了索引")
        let prepared = await store.preparedForChat()
        try expect(prepared.reviewSchedules.first?.id == plan.id, "保存后读取到旧的计划缓存")
        print("PERF: save review schedule with 6351 synthetic records \(elapsed); atomic primary + latest verified mirror, no reconciliation/index refresh")
    }
    private static func lifecycle() async throws {
        let f = try StartupLoadingVerification.fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let store = try verificationStore(storage: f.storage, deferMaintenance: true)
        var plan = ReviewSchedule(template: ReviewTemplate(kind: .work))
        plan.weekday = 6; plan.hour = 18; plan.timeZoneIdentifier = "Asia/Shanghai"
        let now = Date(timeIntervalSince1970: 1_793_616_000)
        try await store.saveReviewSchedule(plan, now: now)
        let reopened = try verificationStore(storage: f.storage, deferMaintenance: true)
        guard let saved = await reopened.snapshot().reviewSchedules.first else { throw Failure(message: "重启后计划丢失") }
        try expect(saved.nextRunAt == plan.nextTrigger(after: now) && !saved.isDue(at: now), "下一次执行时间或时区改变")
        var paused = saved; paused.isEnabled = false
        try await store.saveReviewSchedule(paused, now: now)
        let snapshot = await store.snapshot()
        try expect(snapshot.reviewSchedules.count == 1 && !snapshot.reviewSchedules[0].isEnabled, "暂停计划重复新增或未保存")
        try await store.deleteReviewSchedule(id: saved.id)
        let removed = try verificationStore(storage: f.storage, deferMaintenance: true)
        let removedState = await removed.snapshot()
        try expect(removedState.reviewSchedules.isEmpty, "删除后重启计划仍存在")
    }
    private static func rollbackAndNoop() async throws {
        let f = try StartupLoadingVerification.fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let store = try verificationStore(storage: f.storage, deferMaintenance: true)
        try await store.saveReviewSchedule(ReviewSchedule(template: ReviewTemplate(kind: .personal)))
        let before = await store.snapshot(), saved = before.reviewSchedules[0]
        let backup = f.storage.stateURL.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: f.storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: f.storage.stateURL, withIntermediateDirectories: false)
        // An identical, already saved plan and deleting an absent plan require no disk write.
        try await store.saveReviewSchedule(saved)
        try await store.deleteReviewSchedule(id: UUID())
        var changed = saved; changed.hour = (changed.hour + 1) % 24
        do { try await store.saveReviewSchedule(changed); throw Failure(message: "计划写入失败未上报") }
        catch is Failure { throw Failure(message: "计划写入失败未上报") } catch {}
        do { try await store.deleteReviewSchedule(id: saved.id); throw Failure(message: "删除写入失败未上报") }
        catch is Failure { throw Failure(message: "删除写入失败未上报") } catch {}
        let after = await store.snapshot()
        try expect(after.reviewSchedules == before.reviewSchedules && after.captures == before.captures, "计划保存或删除失败没有回滚")
        try FileManager.default.removeItem(at: f.storage.stateURL)
        try FileManager.default.moveItem(at: backup, to: f.storage.stateURL)
        let reopened = try verificationStore(storage: f.storage, deferMaintenance: true)
        let reopenedState = await reopened.snapshot()
        try expect(reopenedState.reviewSchedules == before.reviewSchedules, "失败后磁盘中的原计划改变")
    }
}
