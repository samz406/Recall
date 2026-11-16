import Foundation
import RecallKit

/// A parked maintenance worker reproduces minutes of optional background work without sleeps.
/// Foreground reads/checks must stay responsive, and late maintenance must never overwrite edits.
enum PeriodReviewLatencyVerification {
    private struct Failure: LocalizedError { let errorDescription: String? }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(errorDescription: message) }
    }
    private actor Gate {
        var started = false
        var readers: [CheckedContinuation<Void, Never>] = []
        var parked: CheckedContinuation<Void, Never>?
        func park() async {
            started = true; readers.forEach { $0.resume() }; readers = []
            await withCheckedContinuation { parked = $0 }
        }
        func wait() async {
            if started { return }
            await withCheckedContinuation { readers.append($0) }
        }
        func release() { parked?.resume(); parked = nil }
    }
    private static func fixture(count: Int = 3, large: Bool = false) throws -> (RecallStorage, FileMemoryStore) {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-period-latency-" + UUID().uuidString))
        var state = RecallState()
        state.privacy.cloudUseEnabled = true
        let today = Calendar.current.startOfDay(for: .now)
        state.captures = (0..<count).map { i in
            let text = "合成 Atlas 第\(i)项验证完成，生产发布尚待确认。"
                + (large ? String(repeating: "仅用于合成性能验证的原文，不能发送到任何网络。", count: 400) : "")
            var capture = CaptureRecord(eventTemplate: .workCheckpoint, createdAt: today.addingTimeInterval(-36_000),
                sourceAppName: "Synthetic Latency", contentHash: "latency-\(i)", ocrText: text, textOrigin: .userInput)
            capture.keepTextIndefinitely = true
            return capture
        }
        for group in 0..<min(5, count) {
            let sources = state.captures.enumerated().filter { $0.offset % min(5, count) == group }.map(\.element)
            let items = sources.map { capture in
                DailySummaryItem(section: .progress, title: "合成交付已核对", detail: "合成交付验证完成，尚未发布。",
                    evidenceIDs: [capture.id], knowledge: DailyItemKnowledge(topic: "合成交付", kind: .matter,
                        status: "inProgress", ownedByUser: true, quotes: ["合成"], category: "work"))
            }
            state.dailySummaries.append(DailySummary(day: today.addingTimeInterval(-Double(group + 1) * 86_400),
                content: "合成回顾", sourceCaptureIDs: sources.map(\.id), todos: [], generationKind: .cloud, items: items))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: storage.stateURL)
        return (storage, try verificationStore(storage: storage, deferMaintenance: true))
    }
    static func run() async throws {
        try await readsDuringMaintenance()
        try await cancellationAndLateCompletion()
        try await concurrentWriteWins()
        try await boundedWait()
        try await snapshotsDoNotRecomputeArchive()
        print("PASS: 5 period latency scenarios (foreground access during maintenance, prompt cancellation, late-result rejection, bounded local waits, cheap repeated snapshots/idle retention)")
    }
    private static func readsDuringMaintenance() async throws {
        let (storage, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let expected = await store.snapshot(), gate = Gate()
        let maintenance = Task { try await store.organizeMemoryInBackground(force: true, onPreparing: { await gate.park() }) }
        await gate.wait()
        let began = Date.now
        let snapshot = try await LocalOperation.run(stage: "合成并发读取", timeout: .seconds(2)) { await store.snapshot() }
        _ = try await LocalOperation.run(stage: "合成并发核对", timeout: .seconds(2)) {
            try await store.validateDailyDerivedReviewMeasured(expected)
        }
        try expect(snapshot.captures == expected.captures, "后台整理阻断或改写了前台快照")
        await gate.release()
        let applied = try await maintenance.value
        let ids = await store.indexedCaptureIDs(matching: "Atlas"), dirty = await store.memoryIndexNeedsRebuild()
        try expect(applied && !dirty && Set(ids) == Set(expected.captures.map(\.id)), "后台整理未完成索引或丢失来源")
        print("PASS: foreground snapshot/source checks remained available during parked background work (\(Int(Date.now.timeIntervalSince(began) * 1000)) ms including resumed maintenance)")
    }
    private static func cancellationAndLateCompletion() async throws {
        let (storage, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let bytes = try Data(contentsOf: storage.stateURL), gate = Gate()
        let maintenance = Task { try await store.organizeMemoryInBackground(force: true, onPreparing: { await gate.park() }) }
        await gate.wait(); maintenance.cancel()
        let cancelled = try await LocalOperation.run(stage: "合成取消", timeout: .seconds(2)) {
            do { _ = try await maintenance.value; return false } catch is CancellationError { return true }
        }
        let cancelledBytes = try Data(contentsOf: storage.stateURL)
        try expect(cancelled && cancelledBytes == bytes, "取消后台任务仍然等待或写入档案")
        await gate.release()
        _ = await store.snapshot()
        let lateBytes = try Data(contentsOf: storage.stateURL)
        try expect(lateBytes == bytes, "后台迟到结果覆盖了已取消的操作")
    }
    private static func concurrentWriteWins() async throws {
        let (storage, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let gate = Gate()
        let maintenance = Task { try await store.organizeMemoryInBackground(force: true, onPreparing: { await gate.park() }) }
        await gate.wait()
        var settings = (await store.snapshot()).memoryKnowledgeSettings
        settings.referenceInChat = false
        try await store.updateMemoryKnowledgeSettings(settings)
        await gate.release()
        let applied = try await maintenance.value
        let saved = await store.snapshot()
        try expect(!applied && !saved.memoryKnowledgeSettings.referencesEnabled, "旧后台快照覆盖了用户的新设置")
    }
    private static func boundedWait() async throws {
        let gate = Gate()
        let call = Task {
            try await LocalOperation.run(stage: "合成超时", timeout: .milliseconds(50)) { await gate.park(); return 1 }
        }
        await gate.wait()
        do { _ = try await call.value; throw Failure(errorDescription: "无响应的本地步骤没有超时") }
        catch is LocalOperationTimeout { }
        await gate.release()
        let second = Gate()
        let cancelled = Task { try await LocalOperation.run(stage: "合成取消", timeout: nil) { await second.park(); return 1 } }
        await second.wait(); cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(errorDescription: "取消没有唤醒不响应取消的本地步骤") }
        catch is CancellationError { }
        await second.release()
    }
    private static func snapshotsDoNotRecomputeArchive() async throws {
        let (storage, store) = try fixture(count: 180, large: true)
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let bytes = try Data(contentsOf: storage.stateURL), started = Date.now
        let expected = await store.snapshot()
        for _ in 0..<100 { _ = await store.snapshot() }
        for _ in 0..<3 { _ = try await store.validateDailyDerivedReviewMeasured(expected) }
        let elapsed = Int(Date.now.timeIntervalSince(started) * 1000)
        let paths = try await store.prune()
        try expect(elapsed < 2_000 && paths.isEmpty, "重复读取或来源核对仍然重新编码原文：\(elapsed)ms")
        let idleBytes = try Data(contentsOf: storage.stateURL)
        try expect(idleBytes == bytes, "空闲保留检查仍触发全库重建或保存")
        print("PASS: 100 snapshots + 3 source checks over \(bytes.count) archive bytes completed in \(elapsed) ms, idle prune left disk unchanged")
    }
}
