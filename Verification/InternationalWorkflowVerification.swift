import Foundation
import RecallKit

private final class RecoverableCredentials: CredentialStore, @unchecked Sendable {
    let memory = InMemoryCredentialStore()
    private let lock = NSLock()
    private var fail = true
    func unlock() { lock.lock(); fail = false; lock.unlock() }
    private func check() throws { lock.lock(); defer { lock.unlock() }; if fail { throw CredentialError.accessDenied } }
    func read(_ id: UUID) throws -> String? { try check(); return try memory.read(id) }
    func write(_ value: String, id: UUID) throws { try check(); try memory.write(value, id: id) }
    func delete(_ id: UUID) throws { try check(); try memory.delete(id) }
}
@MainActor private final class TargetCaptureProbe: ScreenCapturing {
    var calls = 0
    var target = CaptureTarget(processID: 1, bundleIdentifier: "example.atlas", appName: "Atlas", windowID: 1, displayID: 1)
    func currentTarget() -> CaptureTarget? { target }
    func requestScreenRecordingAccess() -> Bool { true }
    func capture(scope: CaptureScope) async throws -> CapturePayload {
        calls += 1
        return CapturePayload(imageData: nil, sourceAppName: target.appName, sourceBundleIdentifier: target.bundleIdentifier, windowTitle: "Atlas")
    }
}
enum InternationalWorkflowVerification {
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw VerificationError.failed(message) }
    }
    static func storage() throws -> RecallStorage { try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("recall-workflow-" + UUID().uuidString)) }
    static func save(_ state: RecallState, to storage: RecallStorage) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; try encoder.encode(state).write(to: storage.stateURL, options: .atomic)
    }
    static func record(_ text: String = "[聊天·自己] I will send the Atlas test report tomorrow.") -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, sourceAppName: "Synthetic Slack", sourceBundleIdentifier: "example.atlas", windowTitle: "Atlas", contentHash: UUID().uuidString, ocrText: text, textOrigin: .screenOCR)
    }
    static func run() async throws {
        try await credentialsAndRecovery()
        try await plannedActions()
        try await importsAndIdentity()
        try evidenceExportAndRoutes()
        try mcpLifecycle()
        try await preflightNeverCapturesExcluded()
        try englishOwnershipMatrix()
        try localizationAndDemo()
        print("PASS: 8 international workflow suites, including 100 English ownership/state cases; credentials, migration recovery, Today, imports, source identity, exports, MCP revocation, preflight and isolated samples")
    }
    static func credentialsAndRecovery() async throws {
        let redacted = PrivacyEngine().redact("api_key: synthetic-example-secret\nAuthorization: Bearer synthetic-header-secret\nsk-proj-synthetic0123456789abcdef")
        try expect(!redacted.contains("synthetic-example-secret") && !redacted.contains("synthetic-header-secret") && !redacted.contains("sk-proj-"), "Credential-like captured text was not redacted")
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let config = LLMConfiguration(baseURLString: "https://model.invalid/v1", model: "synthetic", apiKey: "synthetic-migration-secret")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let state = RecallState(llmConfiguration: config)
        let safe = try encoder.encode(state)
        try expect(!String(decoding: safe, as: UTF8.self).contains(config.apiKey), "State encoder persisted a secret")
        var json = try JSONSerialization.jsonObject(with: safe) as! [String: Any]
        var connection = json["llmConfiguration"] as! [String: Any]; connection["apiKey"] = config.apiKey; json["llmConfiguration"] = connection
        let legacy = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        try legacy.write(to: storage.stateURL)
        let backup = storage.rootURL.appendingPathComponent("recall-state.backup-synthetic.json"); try legacy.write(to: backup)
        let credentials = RecoverableCredentials()
        let store = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: credentials)
        let pending = await store.snapshot()
        try expect(pending.llmConfiguration.apiKey.isEmpty && !pending.llmConfiguration.hasCredential, "Failed migration leaked a legacy key into snapshots")
        try expect(try Data(contentsOf: storage.stateURL) == legacy, "Failed migration overwrote the only durable credential")
        do { try await store.addMessage(ConversationMessage(role: .user, content: "Must not erase legacy data")); throw VerificationError.failed("Pending migration allowed a write") }
        catch is CredentialError {}
        credentials.unlock(); try await store.retryCredentialMaintenance()
        let migrated = await store.snapshot()
        try expect(migrated.llmConfiguration.hasCredential && migrated.llmConfiguration.apiKey.isEmpty, "Migration did not finish")
        try expect(try credentials.read(config.connectionID) == config.apiKey, "Keychain abstraction lost the credential")
        try expect(!String(decoding: try Data(contentsOf: storage.stateURL), as: UTF8.self).contains(config.apiKey), "Migrated state contains secret")
        try expect(!String(decoding: try Data(contentsOf: backup), as: UTF8.self).contains(config.apiKey), "Managed legacy backup contains secret")
        _ = try await store.modelResponder()
        let restarted = try FileMemoryStore(storage: storage, deferMaintenance: true, credentials: credentials)
        _ = try await restarted.modelResponder()
        var edited = await restarted.snapshot().llmConfiguration
        let revision = edited.credentialRevision
        edited.model = "another-synthetic-model"
        try await restarted.updateLLMConfiguration(edited)
        try expect(try credentials.read(config.connectionID) == config.apiKey, "Saving an empty Key field erased the saved credential")
        try expect(await restarted.snapshot().llmConfiguration.credentialRevision == revision, "Reusing a key spuriously changed its revision")
        try await restarted.deleteModelCredential()
        try expect(try credentials.read(config.connectionID) == nil, "Delete credential did not remove Keychain item")
        let latest = await restarted.snapshot()
        try expect(!latest.llmConfiguration.hasCredential, "Delete retained credential state")
    }
    static func plannedActions() async throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let source = record(), now = Date(timeIntervalSince1970: 1_793_600_000)
        let row = ReminderCandidate(title: "Send Atlas test report", detail: "Explicit commitment", sourceCaptureIDs: [source.id], confidence: 1)
        try save(RecallState(captures: [source], reminders: [row]), to: storage)
        let store = try verificationStore(storage: storage, deferMaintenance: true)
        let added = try await store.addToToday(id: row.id, now: now, timeZone: TimeZone(identifier: "America/New_York")!)
        let again = try await store.addToToday(id: row.id, now: now)
        let planned = await store.snapshot().reminders[0]
        try expect(added && !again && planned.status == .planned && planned.dueAt == nil && planned.scheduledAt == nil, "Today action scheduled a notification or duplicated")
        try expect(planned.plannedForDay?.timeZoneIdentifier == "America/New_York" && planned.status.isAction && !planned.status.needsNotification, "Planned day lost its time zone or notification boundary")
        try await store.undoAddToToday(id: row.id, acceptedAt: now)
        try expect(await store.snapshot().reminders[0].status == .proposed, "Today undo failed")
        _ = try await store.addToToday(id: row.id, now: now)
        _ = try await store.deleteCapture(id: source.id)
        let after = await store.snapshot()
        try expect(after.reminders.contains { $0.id == row.id && $0.status == .planned && $0.sourceCaptureIDs.isEmpty }, "Deleting evidence deleted a user-accepted action or kept its private proof")
        let restarted = try verificationStore(storage: storage, deferMaintenance: true)
        try expect(await restarted.snapshot().reminders[0].status == .planned, "Planned enum did not persist")
    }
    static func importsAndIdentity() async throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try verificationStore(storage: storage, deferMaintenance: true)
        let imported = try await store.saveText("[聊天·自己] I will submit the launch report.", title: "External notes", metadata: TextImportMetadata(source: "Otter"))
        let blocks = CaptureUnderstandingEngine.blocks(for: imported)
        try expect(imported.textOrigin == .importedText && blocks.allSatisfy { $0.speaker == .unknown && $0.isReference }, "Imported notes impersonated the user")
        let chat = record("[聊天·角色未知] [发言者·Morgan] [时间·10:20] I will submit the Atlas report.")
        try await store.addCapture(chat)
        var workflow = await store.snapshot().workflow
        workflow.identityBindings = [IdentityBinding(bundleIdentifier: "example.atlas", windowTitle: "Atlas", sender: "Morgan")]
        try await store.updateWorkflow(workflow)
        let bound = await store.snapshot().captures.first { $0.id == chat.id }!
        try expect(CaptureUnderstandingEngine.blocks(for: bound).first?.speaker == .user, "Confirmed sender identity was not used")
        let original = bound.ocrText
        workflow.identityBindings = []; try await store.updateWorkflow(workflow)
        let revoked = await store.snapshot().captures.first { $0.id == chat.id }!
        try expect(revoked.ocrText == original && CaptureUnderstandingEngine.blocks(for: revoked).first?.speaker == .unknown, "Identity revocation rewrote original evidence or kept ownership")
        let mismatched = [IdentityBinding(bundleIdentifier: "example.atlas", windowTitle: "Other workspace", sender: "Morgan")]
        try expect(SourceNormalizer.messages(for: chat, bindings: mismatched).first?.speaker == .unknown, "Identity leaked across windows")
        let session = try await store.startMeeting(title: "Atlas planning")
        _ = try await store.saveText("Decision: ship the smaller release.", title: "Atlas notes", metadata: TextImportMetadata(source: "Granola", meetingSessionID: session.id))
        try await store.finishMeeting(id: session.id)
        let deleted = try await store.deleteMeeting(id: session.id)
        try expect(deleted?.captures.count == 1 && deleted?.meetingSessions?.first?.id == session.id, "Meeting deletion lost its linked notes or grouping")
        if let deleted { _ = try await store.restoreRecentlyDeleted(id: deleted.id) }
        let recovered = await store.snapshot()
        try expect(recovered.workflow.meetings.contains { $0.id == session.id } && recovered.captures.contains { $0.meetingSessionID == session.id }, "Meeting grouping did not recover")
        let duplicate = [IdentityBinding(bundleIdentifier: "example.atlas", windowTitle: "Atlas", sender: "Morgan"), IdentityBinding(bundleIdentifier: "example.atlas", windowTitle: "Atlas", sender: "Morgan")]
        try expect(SourceNormalizer.messages(for: chat, bindings: duplicate).first?.speaker == .unknown, "Ambiguous duplicate identity was promoted")
    }
    static func evidenceExportAndRoutes() throws {
        var source = record("The Atlas rollout passed. <script> [unsafe](file:///private)"), state = RecallState()
        state.captures = [source]
        var answer = ConversationMessage(role: .assistant, content: "Atlas rollout passed.", citations: [source.id])
        answer.sourceVersions = [source.id.uuidString: CaptureUnderstandingEngine.sourceVersion(source, in: state)]
        state.messages = [answer]
        let export = try EvidenceExportBuilder.answer(answer, state: state)
        try expect(export.markdown.contains("Atlas rollout passed") && !export.markdown.contains("<script>") && !export.markdown.contains("](file:"), "Export did not safely quote evidence")
        try expect(EvidenceLinkRouter.captureID(URL(string: EvidenceLinkRouter.link(source.id))!) == source.id, "Local deep link failed")
        try expect(EvidenceLinkRouter.captureID(URL(string: "recall://capture/" + source.id.uuidString + "?path=/private")!) == nil, "Deep link allowed arbitrary query")
        source.ocrText = "Revised evidence"; state.captures = [source]
        try expect(!EvidenceExportBuilder.validate(export, state: state), "Export accepted changed proof")
        do { _ = try EvidenceExportBuilder.answer(answer, state: state); throw VerificationError.failed("Stale answer exported") } catch is WorkflowError {}
        state.captures = []
        do { _ = try EvidenceExportBuilder.answer(answer, state: state); throw VerificationError.failed("Deleted source exported") } catch is WorkflowError {}
    }
    static func mcpLifecycle() throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let source = record("Atlas scope test, not a secret"), outside = record("Outside scope text")
        var state = RecallState(captures: [source, outside])
        state.captures[1].sourceBundleIdentifier = "example.other"
        let grant = MCPGrant(clientName: "synthetic-client", from: .now.addingTimeInterval(-86_400), through: .now.addingTimeInterval(60), appIdentifiers: ["example.atlas"])
        state.workflow.mcpGrant = grant; try save(state, to: storage)
        let server = ReadOnlyMCPServer(storage: storage, token: grant.token)
        func call(_ method: String, _ params: [String: Any] = [:], id: Int? = 1) throws -> String {
            var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]; if let id { body["id"] = id }
            return server.response(to: try JSONSerialization.data(withJSONObject: body)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        try expect(try call("tools/list").contains("Initialize first"), "MCP allowed reads before handshake")
        try expect(try call("initialize", ["clientInfo": ["name": "synthetic-client"], "protocolVersion": "2025-06-18"]).contains("protocolVersion"), "MCP initialization failed")
        _ = try call("notifications/initialized", id: nil)
        let tools = try call("tools/list")
        try expect(tools.contains("search_records") && !tools.contains("delete_record") && !tools.contains("screenshot"), "MCP exposed write/image tools")
        let found = try call("tools/call", ["name": "search_records", "arguments": ["query": "scope"]])
        try expect(found.contains("Atlas scope test") && !found.contains("Outside scope text"), "MCP leaked out-of-scope content")
        let denied = try call("tools/call", ["name": "get_record_excerpt", "arguments": ["id": outside.id.uuidString]])
        try expect(denied.contains("Access revoked"), "MCP ignored application scope")
        state.captures = []; try save(state, to: storage)
        try expect(try call("tools/call", ["name": "get_record_excerpt", "arguments": ["id": source.id.uuidString]]).contains("Access revoked"), "MCP cached deleted evidence")
        state.workflow.mcpGrant = nil; try save(state, to: storage)
        try expect(try call("tools/list").contains("Access revoked"), "MCP did not revoke an active session")
        let log = try String(contentsOf: storage.rootURL.appendingPathComponent("mcp-access.log"), encoding: .utf8)
        try expect(!log.contains(source.ocrText) && !log.contains(grant.token), "MCP audit log leaked text/token")
    }
    @MainActor static func preflightNeverCapturesExcluded() async throws {
        let storage = try storage(); defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        var state = RecallState(); state.privacy.excludedBundleIdentifiers.insert("example.atlas")
        try save(state, to: storage)
        let store = try verificationStore(storage: storage, deferMaintenance: true), capture = TargetCaptureProbe()
        let pipeline = CapturePipeline(store: store, storage: storage, screenCapturer: capture)
        let rule = EventRule.defaults().first { $0.template == .manualMoment }!
        do { _ = try await pipeline.record(using: rule); throw VerificationError.failed("Excluded app captured") } catch is CapturePipelineError {}
        try expect(capture.calls == 0, "Privacy exclusion ran after pixel capture")
        state.privacy.excludedBundleIdentifiers = []; state.privacy.screenCapturePaused = true
        try await store.updatePrivacy(state.privacy)
        do { _ = try await pipeline.record(using: rule); throw VerificationError.failed("Paused capture ran") } catch is CapturePipelineError {}
        try expect(capture.calls == 0, "Pause ran after capture")
    }
    static func englishOwnershipMatrix() throws {
        var accepted = 0, rejected = 0
        for kind in 0..<10 {
            for index in 0..<10 {
                var source = record((kind == 1 ? "[聊天·对方] " : kind == 2 || kind == 7 ? "[聊天·角色未知] " : "[聊天·自己] ") + "I will send Atlas report \(index) tomorrow.")
                if kind == 3 { source.textOrigin = .importedText }
                if kind == 4 { source.ocrText = "[聊天·自己] [内容·资料] An article says to send report \(index)." }
                let id = UUID()
                var knowledge = DailyItemKnowledge(topic: "Atlas report", kind: .matter, status: kind == 5 ? "completed" : kind == 9 ? "cancelled" : "pending", ownedByUser: true, quotes: [source.ocrText])
                knowledge.explicitCommitment = kind != 8; if kind == 6 { knowledge.condition = "if the client approves" }
                let item = DailySummaryItem(section: .actions, title: "Send Atlas report \(index)", detail: "Send the final test report to the Atlas team.", evidenceIDs: [source.id], actionCandidateID: id, knowledge: knowledge)
                let todo = DailySummaryTodo(id: id, title: item.title, detail: item.detail, sourceCaptureIDs: [source.id], priority: .normal)
                var review = DailySummary(day: source.createdAt, content: "", sourceCaptureIDs: [source.id], todos: [todo], generationKind: .cloud, items: [item]); review.items = [item]
                review.modelCoverage = try JSONDecoder().decode(ModelReviewCoverage.self, from: Data(#"{"version":1,"sourceCount":1,"factCount":1,"uncertainBlockCount":0,"createdAt":0}"#.utf8))
                var state = RecallState(captures: [source], dailySummaries: [review])
                _ = DailyReviewReminderEngine.reconcile(&state)
                if kind == 0 { try expect(state.reminders.count == 1, "English explicit action was lost"); accepted += 1 }
                else { try expect(state.reminders.isEmpty, "English negative case \(kind) generated my action"); rejected += 1 }
            }
        }
        try expect(accepted == 10 && rejected == 90, "English fixture matrix was incomplete")
    }
    static func localizationAndDemo() throws {
        UserDefaults.standard.set("en", forKey: RecallLocalization.languageKey)
        defer { UserDefaults.standard.set("zh-Hans", forKey: RecallLocalization.languageKey) }
        try expect(RecallLocalization.text("每日回顾") == "Daily Review" && RecallLocalization.outputCode == "en", "English language selection failed")
        let raw = "[聊天·自己] 原文必须保留"
        try expect(RecallLocalization.text(raw) == raw, "Localization rewrote source evidence")
        let demo = DemoWorkspace.records()
        try expect(demo.count == 2 && demo.allSatisfy { $0.tags == ["Sample"] && $0.imageRelativePath == nil }, "Demo contains live/private captures")
    }
}
