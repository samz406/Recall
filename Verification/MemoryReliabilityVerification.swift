import Foundation
import RecallKit

@MainActor
enum MemoryReliabilityVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }
    static func storage() throws -> RecallStorage { try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-reliability-" + UUID().uuidString)) }
    static func record(_ text: String, age: TimeInterval = 0) -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, createdAt: .now.addingTimeInterval(-age), sourceAppName: "Synthetic", sourceBundleIdentifier: "example.reliability", contentHash: UUID().uuidString, ocrText: text, textOrigin: .userInput)
    }
    static func run() async throws {
        try await damagedArchiveRecovery()
        try await deletionNeverResurrects()
        try await cleanupSurvivesRestart()
        try await conflictingWritersDoNotLoseRecords()
        try await pinnedRetention()
        try groundingMatrix()
        try await verifiedAnswersAndPrivacy()
        print("PASS: 7 memory reliability suites (damage recovery, deletion retry, writer conflict, retention, hostile claims, audit fallback and privacy revocation)")
    }
    static func damagedArchiveRecovery() async throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage), source = record("Synthetic Atlas release test, not yet deployed")
        try await store.addCapture(source)
        let backups = ArchiveReliability.backups(storage)
        try expect(backups.count == 1 && backups[0].captureCount == 1, "A valid latest mirror was not created")
        try FileManager.default.removeItem(at: storage.stateURL)
        do { _ = try verificationStore(storage: storage); throw Failure(errorDescription: "Missing primary silently became blank memory") }
        catch ArchiveReliabilityError.missingPrimary {}
        try ArchiveReliability.restore(backups[0], storage: storage)
        do { _ = try ArchiveReliability.decode(Data("{}".utf8)); throw Failure(errorDescription: "Incomplete JSON became blank memory") }
        catch ArchiveReliabilityError.invalidArchive {}
        let damaged = Data("{broken-primary".utf8)
        try damaged.write(to: storage.stateURL, options: .atomic)
        do { _ = try verificationStore(storage: storage); throw Failure(errorDescription: "A corrupt archive was opened as blank memory") }
        catch is DecodingError {}
        try expect(try Data(contentsOf: storage.stateURL) == damaged, "Failed startup overwrote the damaged file")
        try ArchiveReliability.restore(backups[0], storage: storage)
        let recovered = try verificationStore(storage: storage)
        try expect(await recovered.snapshot().captures.map(\.id) == [source.id], "Verified backup did not restore records")
        let isolated = try FileManager.default.contentsOfDirectory(at: storage.rootURL.appendingPathComponent("Damaged Archives"), includingPropertiesForKeys: nil)
        try expect(isolated.count == 1 && (try Data(contentsOf: isolated[0])) == damaged, "Damaged bytes were not preserved before recovery")
        let mirror = storage.rootURL.appendingPathComponent("Recovery/" + ArchiveReliability.backups(storage)[0].id)
        try Data("{}".utf8).write(to: mirror)
        try expect(ArchiveReliability.backups(storage).isEmpty, "Checksum-damaged backup was offered for recovery")
        do { _ = try ArchiveReliability.decode(Data("{\"schemaVersion\":999}".utf8)); throw Failure(errorDescription: "Future schema was accepted") }
        catch ArchiveReliabilityError.unsupportedVersion {}
    }
    static func deletionNeverResurrects() async throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        var source = record("Synthetic private token to delete")
        source.imageRelativePath = try storage.saveScreenshot(Data("synthetic-png".utf8), captureID: source.id)
        try await store.addCapture(source)
        let old = try Data(contentsOf: storage.stateURL)
        let legacy = storage.rootURL.appendingPathComponent("recall-state.backup-synthetic.json")
        try old.write(to: legacy)
        try await store.clearAllMemoryData()
        try expect(!FileManager.default.fileExists(atPath: legacy.path), "Managed legacy backup survived clear-all")
        try expect(!FileManager.default.fileExists(atPath: storage.screenshotURL(relativePath: source.imageRelativePath!).path), "Screenshot survived a successful clear-all")
        let backup = ArchiveReliability.backups(storage)[0]
        try expect(backup.captureCount == 0, "A pre-deletion restore point survived clear-all")
        try Data("broken".utf8).write(to: storage.stateURL)
        try ArchiveReliability.restore(backup, storage: storage)
        let reopened = try verificationStore(storage: storage)
        try expect(await reopened.snapshot().captures.isEmpty, "Recovery resurrected a deleted record")
    }
    static func cleanupSurvivesRestart() async throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        var source = record("Synthetic cleanup retry")
        source.imageRelativePath = try storage.saveScreenshot(Data("synthetic-png".utf8), captureID: source.id)
        try await store.addCapture(source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storage.screenshotsURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.screenshotsURL.path) }
        try await store.clearAllMemoryData()
        let cleared = await store.snapshot()
        try expect(cleared.captures.isEmpty && !(cleared.pendingFileDeletions ?? []).isEmpty, "Failed file deletion was silently forgotten")
        let reopened = try verificationStore(storage: storage)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.screenshotsURL.path)
        let retry = try await reopened.retryPendingFileCleanup()
        try expect(retry.pendingCount == 0 && !FileManager.default.fileExists(atPath: storage.screenshotURL(relativePath: source.imageRelativePath!).path), "Durable cleanup queue did not retry after restart")
        let orphan = try storage.saveScreenshot(Data("orphan".utf8), captureID: UUID())
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: storage.screenshotURL(relativePath: orphan).path)
        let inFlight = try storage.saveScreenshot(Data("in-flight".utf8), captureID: UUID())
        try expect(try await reopened.queueOrphanScreenshots() == 1, "Orphan cleanup did not distinguish abandoned and in-flight images")
        _ = try await reopened.retryPendingFileCleanup()
        try expect(!FileManager.default.fileExists(atPath: storage.screenshotURL(relativePath: orphan).path) && FileManager.default.fileExists(atPath: storage.screenshotURL(relativePath: inFlight).path), "Orphan cleanup removed a fresh capture or left abandoned bytes")
    }
    static func conflictingWritersDoNotLoseRecords() async throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let first = try verificationStore(storage: storage), stale = try verificationStore(storage: storage, deferMaintenance: true)
        let source = record("Synthetic record from writer one")
        try await first.addCapture(source)
        do { try await stale.addCapture(record("Stale overwrite")); throw Failure(errorDescription: "A stale writer overwrote newer records") }
        catch ArchiveReliabilityError.changedExternally {}
        let reopened = try verificationStore(storage: storage)
        try expect(await reopened.snapshot().captures.map(\.id) == [source.id], "Writer conflict lost committed data")
        try expect(await stale.snapshot().captures.isEmpty, "Failed write left an uncommitted record in memory")
    }
    static func pinnedRetention() async throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        var pinned = record("Synthetic important old work", age: 120 * 86_400)
        pinned.imageRelativePath = try storage.saveScreenshot(Data("synthetic-png".utf8), captureID: pinned.id)
        try await store.addCapture(pinned)
        try await store.setKeepText(id: pinned.id, enabled: true)
        let expired = record("Synthetic expiring old work", age: 120 * 86_400)
        try await store.addCapture(expired)
        _ = try await store.prune()
        let kept = await store.snapshot().captures
        try expect(kept.map(\.id) == [pinned.id] && kept[0].imageRelativePath == nil, "Pin did not preserve text independently of screenshot retention")
        let reopened = try verificationStore(storage: storage)
        try expect(await reopened.snapshot().captures.first?.keepTextIndefinitely == true, "Long-term retention was not persisted")
        try await reopened.setKeepText(id: pinned.id, enabled: false)
        _ = try await reopened.prune()
        try expect(await reopened.snapshot().captures.isEmpty, "Unpinning did not restore the original expiry policy")
    }
    static func groundingMatrix() throws {
        let source = record("[聊天·自己] Atlas 测试通过，尚未上线，等审批后发布。")
        let proof = AnswerGrounding.Quote(sourceID: source.id, quote: source.ocrText)
        let bad = [
            AnswerGrounding.Claim(statement: "Atlas 已上线", actor: "user", status: "completed", evidence: [proof]),
            .init(statement: "Atlas 将在 2028 年上线", evidence: [proof]),
            .init(statement: "Atlas 将在周五上线", evidence: [proof]),
            .init(statement: "Atlas 已发布", evidence: [.init(sourceID: source.id, quote: "Atlas 已发布")]),
            .init(statement: "伪造来源", evidence: [.init(sourceID: UUID(), quote: source.ocrText)])
        ]
        for claim in bad {
            let result = AnswerGrounding.validate([claim], records: [source])
            try expect(result.rejectedCount > 0 && !result.content.hasPrefix(claim.statement), "Unsupported claim passed the local gate")
        }
        var other = source; other.id = UUID(); other.ocrText = "[聊天·对方] 我会在周五提交 Atlas 报告。"; other.textOrigin = .screenOCR
        let ownership = AnswerGrounding.Claim(statement: "你会在周五提交 Atlas 报告", actor: "user", status: "pending", evidence: [.init(sourceID: other.id, quote: other.ocrText)])
        try expect(AnswerGrounding.validate([ownership], records: [other]).rejectedCount == 1, "Other speaker became the user's commitment")
        let good = AnswerGrounding.Claim(statement: "Atlas 测试通过，尚未上线", actor: "user", evidence: [proof])
        let partial = AnswerGrounding.validate([good] + bad, records: [source])
        try expect(partial.content.contains(good.statement) && partial.rejectedCount == bad.count && partial.sourceIDs == [source.id], "One invalid claim discarded supported claims")
    }
    static func verifiedAnswersAndPrivacy() async throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage)
        let source = record("[聊天·自己] Atlas 测试通过，尚未上线。")
        try await store.addCapture(source)
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        try await store.updateLLMConfiguration(LLMConfiguration(provider: .openAICompatible, baseURLString: "https://example.test/v1", model: "synthetic", apiKey: "synthetic"))
        let model = ReliabilityModel(source: source)
        var visibleDraft = false
        let answer = try await MemoryAssistant(store: store).ask("Atlas 是否上线", model: model, onPartial: { _ in visibleDraft = true })
        try expect(!answer.content.contains("Atlas 已上线") && answer.content.contains("尚未上线") && !visibleDraft, "Unverified completion was displayed")
        let mixed = ReliabilityModel(source: source, mixedAudit: true)
        let repaired = try await MemoryAssistant(store: store).ask("Atlas 是否上线", model: mixed)
        try expect(repaired.content.contains("测试通过，尚未上线") && repaired.content.contains("已省略"), "One malformed audit row discarded valid claims")
        let offline = ReliabilityModel(source: source, auditFailure: true)
        let offlineAnswer = try await MemoryAssistant(store: store).ask("Atlas 是否上线", model: offline)
        try expect(offlineAnswer.content.contains("原文"), "Offline verification discarded retrievable evidence")
        let delayed = ReliabilityModel(source: source, auditDelay: true)
        let beforeCancel = await store.snapshot().messages.filter { $0.role == .assistant }.count
        let task = Task { try await MemoryAssistant(store: store).ask("Atlas 是否上线", model: delayed) }
        for _ in 0..<200 { if await delayed.calls >= 2 { break }; try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        do { _ = try await task.value; throw Failure(errorDescription: "Cancelled verification still returned") }
        catch is CancellationError {}
        try expect(await store.snapshot().messages.filter { $0.role == .assistant }.count == beforeCancel, "Cancelled verification persisted an answer")
        let badAudit = ReliabilityModel(source: source, invalidAudit: true)
        let fallback = try await MemoryAssistant(store: store).ask("Atlas 是否上线", model: badAudit)
        try expect(fallback.content.contains("原文") && fallback.content.contains("尚未上线"), "Invalid audit did not fall back to source excerpts")
        let revoke = ReliabilityModel(source: source, revoke: store)
        do { _ = try await MemoryAssistant(store: store).ask("Atlas 是否上线", model: revoke); throw Failure(errorDescription: "Revoked privacy did not stop later calls") }
        catch is LLMError {}
        try expect(await revoke.calls == 1, "Verification sent data after cloud permission was revoked")
        try await store.clearAllMemoryData()
        try await store.updatePrivacy(PrivacySettings(cloudUseEnabled: true))
        let empty = ReliabilityModel(source: source)
        let missing = try await MemoryAssistant(store: store).ask("Atlas 是否上线", model: empty)
        try expect(await empty.calls == 0 && missing.content == AnswerGrounding.noEvidence, "Empty scope called a model or asserted that no event happened")
    }
}

private actor ReliabilityModel: LLMResponding {
    let source: CaptureRecord
    let invalidAudit: Bool
    let mixedAudit: Bool
    let auditFailure: Bool
    let auditDelay: Bool
    let revoke: FileMemoryStore?
    var calls = 0
    init(source: CaptureRecord, invalidAudit: Bool = false, mixedAudit: Bool = false, auditFailure: Bool = false, auditDelay: Bool = false, revoke: FileMemoryStore? = nil) { self.source = source; self.invalidAudit = invalidAudit; self.mixedAudit = mixedAudit; self.auditFailure = auditFailure; self.auditDelay = auditDelay; self.revoke = revoke }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        calls += 1
        if request.purpose == .answerVerification {
            if auditFailure { throw URLError(.notConnectedToInternet) }
            if auditDelay { try await Task.sleep(for: .seconds(30)) }
            if invalidAudit { return LLMAnswer(content: "not-json", citedCaptureIDs: []) }
            let claim = AnswerGrounding.Claim(statement: "Atlas 测试通过，尚未上线", actor: "user", evidence: [.init(sourceID: source.id, quote: source.ocrText)])
            let data = try JSONEncoder().encode(["claims": [claim]])
            if mixedAudit {
                var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                object["claims"] = (object["claims"] as! [Any]) + [["statement": "malformed", "evidence": [["sourceID": "not-a-uuid"]]]]
                let mixed = try JSONSerialization.data(withJSONObject: object)
                return LLMAnswer(content: String(decoding: mixed, as: UTF8.self), citedCaptureIDs: [])
            }
            return LLMAnswer(content: String(decoding: data, as: UTF8.self), citedCaptureIDs: [])
        }
        if let revoke { try await revoke.updatePrivacy(PrivacySettings(cloudUseEnabled: false)) }
        return LLMAnswer(content: "{\"answer\":\"Atlas 已上线\",\"citations\":[\"\(source.id.uuidString)\"]}", citedCaptureIDs: [source.id])
    }
}
