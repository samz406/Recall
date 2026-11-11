import Foundation
import RecallKit

enum PeriodReviewDeletionVerification {
    private struct Failure: LocalizedError { let errorDescription: String? }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }
    static func run() async throws {
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        let source = try ManualMatterNote(title: "Atlas 合成验收归档", detail: "验收归档已完成，保留边界检查结果。", status: .completed,
            eventAt: now.addingTimeInterval(-3600), reviewCategory: .work).capture(recordedAt: now.addingTimeInterval(-3600))
        var sample = RecallState(captures: [source])
        let period = ReviewPeriod(start: now.addingTimeInterval(-86_400), end: now)
        let original = try await WeeklyReviewEngine().generate(in: sample, period: period, template: ReviewTemplate(kind: .work), now: now)
        var sameName = original; sameName.id = UUID()
        var stale = original; stale.id = UUID(); stale.invalidate(at: now)
        var plan = ReviewSchedule(template: original.template)
        plan.lastReportID = stale.id; plan.nextRunAt = now.addingTimeInterval(-60); plan.retryAfter = now.addingTimeInterval(-30); plan.failureCount = 2
        stale.scheduleID = plan.id
        sample.weeklyReports = [original, sameName, stale]; sample.reviewSchedules = [plan]
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("period-review-delete-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sample).write(to: storage.stateURL)
        let store = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        let before = await store.snapshot()
        guard let deletion = try await store.deleteWeeklyReport(id: stale.id, now: now) else { throw Failure(errorDescription: "待更新回顾没有删除结果") }
        let deleted = await store.snapshot()
        try expect(Set(deleted.weeklyReports.map(\.id)) == [original.id, sameName.id], "删除无效回顾失败，或误删同名同期的另一份回顾")
        try expect(deleted.captures == before.captures && deleted.dailySummaries == before.dailySummaries, "删除回顾删除了原始记录或每日回顾")
        try expect(deletion.weeklyReports?.map(\.id) == [stale.id] && deletion.expiresAt > now, "回顾未进入可恢复的最近删除")
        try expect(deleted.reviewSchedules[0].lastReportID == nil && deleted.reviewSchedules[0].retryAfter == nil && deleted.reviewSchedules[0].nextRunAt! > now,
            "删除后旧计划仍准备立即重建这份回顾")
        let work = WeeklyReviewWork.next(in: deleted, at: now, modelAvailable: true)
        if case .some = work { throw Failure(errorDescription: "删除后立即生成了同一期回顾") }
        let repeated = try await store.deleteWeeklyReport(id: stale.id, now: now)
        try expect(repeated == nil, "重复删除又生成了删除记录")
        try await store.organizeMemory(force: true, now: now)
        let reopened = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: InMemoryCredentialStore())
        let persisted = await reopened.snapshot()
        try expect(!persisted.weeklyReports.contains { $0.id == stale.id }, "重新整理或重启恢复了已删除回顾")
        _ = try await store.restoreRecentlyDeleted(id: deletion.id, now: now.addingTimeInterval(1))
        try expect(await store.snapshot().weeklyReports.contains { $0.id == stale.id }, "七天内无法显式恢复回顾")

        // A late result may not put the exact deleted ID back into the live list.
        _ = try await store.deleteWeeklyReport(id: original.id, now: now.addingTimeInterval(2))
        do {
            _ = try await store.commitWeeklyReport(original, now: now.addingTimeInterval(3))
            throw Failure(errorDescription: "后台晚到的保存恢复了已删除回顾")
        } catch WeeklyReviewError.changedSources {}
        let safe = await store.snapshot()
        let backup = storage.stateURL.appendingPathExtension("delete-backup")
        try FileManager.default.moveItem(at: storage.stateURL, to: backup)
        try FileManager.default.createDirectory(at: storage.stateURL, withIntermediateDirectories: false)
        do { _ = try await store.deleteWeeklyReport(id: sameName.id); throw Failure(errorDescription: "删除写入失败却返回成功") }
        catch is Failure { throw Failure(errorDescription: "删除写入失败却返回成功") } catch {}
        let failed = await store.snapshot()
        try expect(failed.weeklyReports == safe.weeklyReports && failed.recentlyDeletedMemories.count == safe.recentlyDeletedMemories.count,
            "删除失败没有恢复列表与最近删除")
        try FileManager.default.removeItem(at: storage.stateURL)
        try FileManager.default.moveItem(at: backup, to: storage.stateURL)
        _ = try await store.deleteWeeklyReport(id: sameName.id)
        print("PASS: period-review deletion removes the exact stale/duplicate record, preserves sources, survives maintenance/reopen, supports restore, blocks late saves and rolls back write failures")
    }
}
