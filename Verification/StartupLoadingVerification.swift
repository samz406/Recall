import Foundation
import RecallKit

enum StartupLoadingVerification {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ModelReviewVerification.Failure(message: message) }
    }
    struct Fixture {
        var storage: RecallStorage
        var state: RecallState
        var bytes: Data
    }
    static func fixture(count: Int = 3) throws -> Fixture {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-startup-" + UUID().uuidString))
        var state = RecallState()
        state.captures = (0..<count).map { index in
            CaptureRecord(eventTemplate: .workCheckpoint, createdAt: Date.now.addingTimeInterval(-Double(index * 3)),
                sourceAppName: "合成启动验证", sourceBundleIdentifier: "example.synthetic-startup", contentHash: "startup-\(index)",
                ocrText: "[聊天·自己] Atlas 第 \(index) 组分页边界验证已经完成。" + String(repeating: "合成记录正文保留，不在启动时重新归纳。", count: 15), textOrigin: .userInput)
        }
        state.dailySummaries = (0..<min(20, count)).map { index in
            DailySummary(day: Date.now.addingTimeInterval(-Double(index * 86_400)), content: "已保存的 Atlas 回顾第 \(index) 份，原文与用户编辑保持不变。",
                sourceCaptureIDs: [state.captures[index].id], todos: [], generationKind: .cloud)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(state)
        try bytes.write(to: storage.stateURL)
        return Fixture(storage: storage, state: state, bytes: bytes)
    }
    static func run() async throws {
        try await firstSnapshotSkipsMaintenance()
        try await idleRecoveryDoesNotRewriteArchive()
        try await startupWithdrawsKnownUnusableReports()
        try await maintenanceRunsAfterSnapshot()
        try await inflightRecoveryKeepsProgress()
        print("PASS: 5 startup-loading scenarios (saved reports first, no idle rewrites, source safety, deferred indexing and recovery)")
    }
    static func firstSnapshotSkipsMaintenance() async throws {
        let f = try fixture(count: 1_200)
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let start = Date.now
        let store = try FileMemoryStore(storage: f.storage, deferMaintenance: true)
        let state = await store.snapshot(), dirty = await store.memoryIndexNeedsRebuild()
        let elapsed = Int(Date.now.timeIntervalSince(start) * 1_000)
        try expect(state.captures.count == 1_200 && state.dailySummaries.count == 20
            && state.dailySummaries.map(\.content) == f.state.dailySummaries.map(\.content), "首次快照没有直接返回已保存回顾")
        try expect(state.memoryKnowledge.claims.isEmpty && state.episodes.isEmpty && dirty,
            "首次读取仍执行全库归纳或索引重建")
        let disk = try Data(contentsOf: f.storage.stateURL)
        try expect(disk == f.bytes, "首次读取重复写回整份档案")
        print("PASS: startup first snapshot restored 1200 synthetic records and 20 reviews in \(elapsed) ms, without archive rewrites or index rebuild")
    }
    static func idleRecoveryDoesNotRewriteArchive() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let store = try FileMemoryStore(storage: f.storage, deferMaintenance: true)
        try await store.recoverCaptureUnderstandingJobs()
        try await store.recoverSummaryFeedbackJobs()
        let disk = try Data(contentsOf: f.storage.stateURL), state = await store.snapshot()
        try expect(disk == f.bytes && state.dailySummaries.count == f.state.dailySummaries.count,
            "没有待恢复任务时仍重复保存和维护全库")
    }
    static func startupWithdrawsKnownUnusableReports() async throws {
        var f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        f.state.captures[0].sourceBundleIdentifier = "example.excluded-startup"
        f.state.privacy.excludedBundleIdentifiers = ["example.excluded-startup"]
        f.state.dailySummaries[1].sourceCaptureIDs = [UUID()]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(f.state).write(to: f.storage.stateURL)
        let store = try FileMemoryStore(storage: f.storage, deferMaintenance: true), state = await store.snapshot()
        try expect(state.dailySummaries.count == 1 && state.dailySummaries[0].id == f.state.dailySummaries[2].id,
            "快速首屏显示了来源已删除或已排除的回顾")
    }
    static func maintenanceRunsAfterSnapshot() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let store = try FileMemoryStore(storage: f.storage, deferMaintenance: true)
        let before = await store.snapshot()
        try await store.organizeMemory(force: true)
        let after = await store.snapshot(), dirty = await store.memoryIndexNeedsRebuild()
        let indexed = await store.indexedCaptureIDs(matching: "Atlas")
        try expect(!dirty && Set(indexed) == Set(f.state.captures.map(\.id))
            && before.dailySummaries.map(\.content) == after.dailySummaries.map(\.content), "延后维护没有完成索引，或改写已保存回顾")
    }
    static func inflightRecoveryKeepsProgress() async throws {
        var f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        var job = CaptureUnderstandingJob(captureID: f.state.captures[0].id)
        job.state = .processing; job.lease = UUID(); job.nextPage = 1; job.pageCount = 2; job.coveredBlocks = 24
        f.state.understandingJobs = [job]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(f.state).write(to: f.storage.stateURL)
        let store = try FileMemoryStore(storage: f.storage, deferMaintenance: true)
        let first = await store.snapshot()
        try expect(first.dailySummaries.count == 3 && first.understandingJobs[0].state == .processing, "首屏前已提前运行恢复维护")
        try await store.recoverCaptureUnderstandingJobs()
        let recovered = await store.snapshot(), dirty = await store.memoryIndexNeedsRebuild()
        try expect(recovered.understandingJobs[0].state == .queued && recovered.understandingJobs[0].lease == nil
            && recovered.understandingJobs[0].nextPage == 1 && recovered.understandingJobs[0].coveredBlocks == 24
            && recovered.memoryKnowledge.claims.isEmpty && dirty, "恢复租约丢失检查点或同步执行全库维护")
    }
}
