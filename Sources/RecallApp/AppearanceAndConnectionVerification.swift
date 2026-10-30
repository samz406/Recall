import AppKit
import SwiftUI
import RecallKit

extension RecallLayoutPreviews {
    /// Native, synthetic-only checks for persistent theme overrides and stale async tests.
    @MainActor static func verifyAppearanceAndConnection() async throws {
        let suite = "im.recall.appearance-verification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let originalAppearance = NSApp.appearance
        defer { defaults.removePersistentDomain(forName: suite); NSApp.appearance = originalAppearance }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw SettingsVerificationFailure.failed(message) }
        }
        try require(RecallAppearance.load(from: defaults) == .system, "new installation must follow macOS")
        defaults.set("unrecognized", forKey: RecallAppearance.storageKey)
        try require(RecallAppearance.load(from: defaults) == .system, "unknown appearance must follow macOS")
        defaults.set(RecallAppearance.dark.rawValue, forKey: RecallAppearance.storageKey)
        try require(RecallAppearance.load(from: UserDefaults(suiteName: suite)!) == .dark, "appearance must survive reloading defaults")

        var observedScheme: ColorScheme?
        var secondaryScheme: ColorScheme?
        let probe = SettingsAppearanceProbe { observedScheme = $0 }
            .frame(width: 100, height: 100).recallColors().defaultAppStorage(defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: probe)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let secondary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        secondary.contentView = NSHostingView(rootView: SettingsAppearanceProbe { secondaryScheme = $0 }
            .frame(width: 100, height: 100).recallColors().defaultAppStorage(defaults))
        secondary.orderFront(nil)
        defer { secondary.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        try require(observedScheme == .dark && NSApp.appearance?.name == .darkAqua && window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, "dark selection must reach SwiftUI and AppKit")
        try require(secondaryScheme == .dark, "theme must apply to independent settings windows")
        defaults.set(RecallAppearance.light.rawValue, forKey: RecallAppearance.storageKey)
        try await Task.sleep(for: .milliseconds(100))
        try require(observedScheme == .light && NSApp.appearance?.name == .aqua && window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "theme selection must update the open window immediately")
        try require(secondaryScheme == .light, "all open windows must update together")
        defaults.set(RecallAppearance.system.rawValue, forKey: RecallAppearance.storageKey)
        try await Task.sleep(for: .milliseconds(100))
        try require(NSApp.appearance == nil && window.appearance == nil, "system selection must release native overrides")
        try require(secondary.appearance == nil, "system selection must release independent window overrides")

        let configuration = LLMConfiguration(baseURLString: "https://model.example.invalid/v1", model: "synthetic-model", apiKey: "synthetic-verification-only", anthropicVersion: "2023-06-01", maxOutputTokens: 2048)
        let draft = ModelConnectionDraft(configuration: configuration, savedKeyExists: true)
        try require(draft.apiKey.isEmpty && draft.canSave && draft.testState == .idle, "saved credentials must be reusable without being revealed or marked tested")
        draft.modelName = "changed-model"
        try require(!draft.canSave, "changed draft requires a matching test")
        draft.test { request in
            guard request.apiKey == configuration.apiKey && request.maxOutputTokens == 2048 else { throw SettingsVerificationFailure.failed("test lost configuration") }
        }
        try await awaitTest(draft)
        try require(draft.canSave && draft.testState == .success && draft.apiKey.isEmpty, "successful test must allow save without exposing saved key")
        draft.apiKey = " new-synthetic-value "
        try require(!draft.canSave && draft.configuration.apiKey == "new-synthetic-value", "typing a replacement must invalidate the test and trim the replacement")
        draft.test { _ in throw LLMError.serviceError("401 secret-server-response") }
        try await awaitTest(draft)
        guard case .failure(let reason) = draft.testState else { throw SettingsVerificationFailure.failed("failed test was not shown") }
        try require(!draft.canSave && !reason.contains("secret-server-response") && reason.contains("认证"), "failure must be useful without echoing server data")

        let gate = SettingsTestGate()
        draft.test { _ in await gate.wait() }
        await gate.awaitPending()
        draft.modelName = "newer-model"
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        try require(draft.testState == .idle && !draft.canSave, "a result for an edited draft must not re-enable saving")
        let closeGate = SettingsTestGate()
        draft.test { _ in await closeGate.wait() }
        await closeGate.awaitPending()
        draft.invalidateTest() // same operation used by Cancel, X and sheet dismissal
        await closeGate.release()
        try await Task.sleep(for: .milliseconds(30))
        try require(draft.testState == .idle && !draft.isTesting, "dismissal must reject a late response")

        draft.baseURL = "https:///"
        try require(!draft.canTest && !draft.canSave, "hostless URLs must be invalid")
        draft.baseURL = "https://user:password@example.invalid"
        try require(!draft.canTest, "URLs must not contain credentials")
        let empty = ModelConnectionDraft(configuration: LLMConfiguration(), savedKeyExists: false)
        try require(empty.apiKey.isEmpty && !empty.canTest && !empty.canSave, "new connection must require a credential")
        print("PASS: native theme persistence, immediate switching, system inheritance, saved-key reuse, test gating, safe failures and stale-result cancellation")
    }
    @MainActor private static func awaitTest(_ draft: ModelConnectionDraft) async throws {
        for _ in 0..<100 {
            if !draft.isTesting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SettingsVerificationFailure.failed("synthetic connection test timed out")
    }
}

private struct SettingsAppearanceProbe: View {
    @Environment(\.colorScheme) private var scheme
    var changed: (ColorScheme) -> Void
    var body: some View { Color.clear.onAppear { changed(scheme) }.onChange(of: scheme) { _, next in changed(next) } }
}

private actor SettingsTestGate {
    private var pending: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { pending = $0 } }
    func awaitPending() async { while pending == nil { await Task.yield() } }
    func release() { pending?.resume(); pending = nil }
}
private enum SettingsVerificationFailure: Error { case failed(String) }
