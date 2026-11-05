import Foundation
import RecallKit

extension RecallLayoutPreviews {
    static func verifyMemoryReliabilityEntries() async throws {
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-native-recovery-" + UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let broken = Data("{synthetic-broken-archive".utf8)
        try broken.write(to: storage.stateURL)
        let startup = RecallStartupController(storage: storage, automatic: false)
        await startup.open()
        guard startup.model == nil, startup.failure != nil, !startup.isWorking,
              try Data(contentsOf: storage.stateURL) == broken else { throw NativeReliabilityFailure(message: "坏档案没有进入安全恢复页面") }
        let source = CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "Synthetic", contentHash: UUID().uuidString, ocrText: "Synthetic important text", textOrigin: .userInput)
        let model = try RecallAppModel(previewState: RecallState(captures: [source]))
        defer { try? FileManager.default.removeItem(at: model.storage.rootURL) }
        model.setKeepText(source.id, enabled: true)
        for _ in 0..<200 {
            if model.state.captures.first?.keepTextIndefinitely == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let saved = await model.store.snapshot()
        guard saved.captures.first?.keepTextIndefinitely == true else { throw NativeReliabilityFailure(message: "长期保留入口未保存") }
        await model.localMaintenance(retry: true)
        guard !model.archiveBackupPending, model.pendingFileCleanupCount == 0 else { throw NativeReliabilityFailure(message: "备份重试入口未完成") }
        print("PASS: native recovery failure, long-term retention and local maintenance entry points")
    }
}
private struct NativeReliabilityFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
