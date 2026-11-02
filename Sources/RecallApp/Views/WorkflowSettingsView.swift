import SwiftUI
import AppKit
import Carbon
import UniformTypeIdentifiers
import RecallKit

private func w(_ chinese: String, _ english: String) -> String { RecallLocalization.both(chinese, english) }

struct WorkflowSettingsView: View {
    @EnvironmentObject private var model: RecallAppModel
    @AppStorage(RecallLocalization.languageKey) private var language = "system"
    @AppStorage(RecallLocalization.outputKey) private var outputLanguage = "system"
    @State private var recordShortcut = GlobalShortcutBinding.load("record", fallback: .record)
    @State private var askShortcut = GlobalShortcutBinding.load("ask", fallback: .ask)
    @State private var identityCapture: UUID?
    @State private var sender = ""
    @State private var meetingTitle = ""
    @State private var client = ""
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var through = Date.now
    @State private var reviews = true
    @State private var allowedApp = ""
    @State private var confirmMCP = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let warning = model.credentialMaintenanceWarning {
                VStack(alignment: .leading, spacing: 10) {
                    Text(warning).font(.callout).foregroundStyle(RecallPalette.warning)
                    Button(w("重试凭据迁移与备份清理", "Retry credential migration & cleanup")) {
                        Task { do { try await model.store.retryCredentialMaintenance(); model.credentialMaintenanceWarning = nil; await model.refresh() }
                               catch { model.noticeMessage = error.localizedDescription } }
                    }
                }.recallSurface()
            }
            languageSection
            shortcutSection
            meetingSection
            identitySection
            mcpSection
        }
    }
    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(w("使用偏好", "Preferences")).font(.title3.bold())
            Picker(w("界面语言", "Interface language"), selection: $language) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            Picker(w("回顾输出语言", "Review language"), selection: $outputLanguage) {
                Text(w("跟随界面", "Follow interface")).tag("system")
                Text("English").tag("en"); Text("简体中文").tag("zh-Hans")
            }
            Text(w("仅影响新生成的内容，原文与历史回顾保持不变。", "Applies to new output. Original quotes and saved reviews stay unchanged."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            HStack {
                Button(w("写一条记录", "Write a record")) { model.showsTextEntry = true }
                Button(w("查看首次体验", "Try the sample")) { model.showsOnboarding = true }
            }
        }.recallSurface()
    }
    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(w("全局快捷键", "Global shortcuts")).font(.headline)
            shortcutRow(w("记录此刻", "Record a moment"), binding: $recordShortcut, action: "record")
            shortcutRow(w("打开问一问", "Open Ask Recall"), binding: $askShortcut, action: "ask")
            Label(model.shortcutsReady ? w("快捷键已注册", "Shortcuts registered") : w("快捷键未注册或有冲突，请更换组合。", "A shortcut could not be registered. Try another combination."), systemImage: model.shortcutsReady ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption).foregroundStyle(model.shortcutsReady ? RecallPalette.accent : RecallPalette.warning)
            Text(w("点击组合后按新组合，至少包含 ⌘ 或 ⌃。这是明确触发，不开启 Enter 监听。应用退出后快捷键停止。", "Click a shortcut and press a new combination including ⌘ or ⌃. This does not enable Enter monitoring. Shortcuts stop when Recall quits."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        }.recallSurface()
    }
    private func shortcutRow(_ title: String, binding: Binding<GlobalShortcutBinding>, action: String) -> some View {
        HStack {
            Toggle(title, isOn: binding.enabled).onChange(of: binding.wrappedValue.enabled) { _, _ in model.saveShortcut(binding.wrappedValue, action: action) }
            ShortcutRecorder(binding: binding) { model.saveShortcut($0, action: action) }.frame(width: 180, height: 32)
        }
    }
    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(w("会议记录", "Meeting moments")).font(.headline)
            Text(w("只在你点击开始和结束时各记录一帧，不录音、不自动参会。先切到会议窗口，再回到这里。", "Save one frame when you start and one when you finish. No audio or meeting bot. Switch to the meeting window, then return here."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            if let target = model.lastExternalTarget { Text(w("将记录：", "Capture target: ") + target.appName).font(.caption).foregroundStyle(RecallPalette.accent) }
            HStack {
                TextField(w("会议名称", "Meeting title"), text: $meetingTitle).textFieldStyle(.roundedBorder)
                Button(w("开始并记录", "Start & save")) { model.startMeeting(meetingTitle); meetingTitle = "" }
                    .disabled(meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.lastExternalTarget == nil || model.state.privacy.screenCapturePaused)
            }
            ForEach(model.state.workflow.meetings.filter { $0.endedAt == nil }) { meeting in
                HStack {
                    VStack(alignment: .leading) { Text(meeting.title); Text(meeting.startedAt.formatted()).font(.caption).foregroundStyle(RecallPalette.secondary) }
                    Spacer()
                    Button(w("结束并记录", "Finish & save")) { model.endMeeting(meeting.id) }.disabled(model.lastExternalTarget == nil || model.state.privacy.screenCapturePaused)
                }
            }
            Button(w("粘贴或导入纪要", "Paste or import notes")) { model.showsTextEntry = true }
        }.recallSurface()
    }
    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(w("聊天中的我", "Your chat identity")).font(.headline)
            Text(w("只对你选择的应用与窗口生效。填写截图中准确的发言者名称；同名或无法定位时保留未知，不把其他人的话当作你的承诺。", "Applies only to the selected app and window. Enter your exact visible sender name. Unclear or ambiguous authors remain unknown."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            Picker(w("来源窗口", "Source window"), selection: $identityCapture) {
                Text(w("选择已记录的聊天窗口", "Choose a saved chat window")).tag(Optional<UUID>.none)
                ForEach(identitySources) { record in
                    Text((record.sourceAppName ?? "App") + " · " + (record.windowTitle ?? "")).tag(Optional(record.id))
                }
            }
            HStack {
                TextField(w("我的发言者名称", "My sender name"), text: $sender).textFieldStyle(.roundedBorder)
                Button(w("确认身份", "Confirm identity")) { if let id = identityCapture { model.saveIdentity(captureID: id, sender: sender); sender = "" } }
                    .disabled(identityCapture == nil || sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(model.state.workflow.identityBindings) { identity in
                HStack {
                    Text(identity.sender + " · " + identity.windowTitle).font(.caption)
                    Spacer(); Button(w("撤销", "Revoke"), role: .destructive) { model.removeIdentity(identity.id) }
                }
            }
        }.recallSurface()
    }
    private var identitySources: [CaptureRecord] {
        var seen = Set<String>()
        return model.state.captures.filter {
            guard $0.windowTitle != nil, $0.sourceBundleIdentifier != nil else { return false }
            let profile = SourceProfile.resolve(app: $0.sourceAppName, bundle: $0.sourceBundleIdentifier, title: $0.windowTitle)
            return [.slack, .teams].contains(profile) && seen.insert(($0.sourceBundleIdentifier ?? "") + "\n" + ($0.windowTitle ?? "")).inserted
        }
    }
    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(w("Agent 只读访问", "Read-only access for agents")).font(.headline)
            Text(w("仅开放所选范围的文本，不提供图片、密钥或写入工具。Agent 收到文字后可能发给它使用的模型。客户端名称只是标签，访问令牌才是授权，请仅交给信任的本机客户端。", "Expose only text within your chosen scope. No images, credentials or write tools. An agent may send excerpts to its model. Client names are labels; protect the access token and share it only with a trusted local client."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            if let grant = model.state.workflow.mcpGrant {
                Label(grant.clientName, systemImage: "lock.open").foregroundStyle(RecallPalette.accent)
                Text(grant.from.formatted() + " — " + grant.through.formatted()).font(.caption)
                Text(w("使用自行构建的 recall-cli 作为 command；参数为 mcp，环境变量见复制内容。", "Use your locally built recall-cli as the command, with argument mcp. The copied configuration includes the environment token."))
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                HStack {
                    Button(w("复制连接配置", "Copy connection config")) { copyMCP(grant) }
                    Button(w("撤销访问", "Revoke access"), role: .destructive) { model.revokeMCP() }
                }
            } else {
                TextField(w("客户端名称（须与 MCP clientInfo.name 一致）", "Client name (must match MCP clientInfo.name)"), text: $client).textFieldStyle(.roundedBorder)
                DatePicker(w("从", "From"), selection: $from)
                DatePicker(w("至", "Through"), selection: $through)
                Picker(w("应用范围", "Application scope"), selection: $allowedApp) {
                    Text(w("全部可用来源", "All eligible sources")).tag("")
                    ForEach(apps, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(w("允许读取此范围的每日回顾", "Allow daily reviews in this scope"), isOn: $reviews)
                Button(w("授权此范围", "Authorize this scope")) { confirmMCP = true }
                    .disabled(client.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || from > through)
            }
        }.recallSurface()
        .confirmationDialog(w("允许本机 Agent 读取这些内容？", "Allow a local agent to read this scope?"), isPresented: $confirmMCP, titleVisibility: .visible) {
            Button(w("授权", "Authorize")) { model.setMCP(client: client, from: from, through: through, reviews: reviews, appIdentifiers: allowedApp.isEmpty ? [] : [allowedApp]) }
            Button(w("取消", "Cancel"), role: .cancel) {}
        }
    }
    private var apps: [(String, String)] {
        var seen = Set<String>()
        return model.state.captures.compactMap { record in
            guard let id = record.sourceBundleIdentifier, seen.insert(id).inserted else { return nil }; return (id, record.sourceAppName ?? id)
        }.sorted { $0.1 < $1.1 }
    }
    private func copyMCP(_ grant: MCPGrant) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = w("选择你构建的 recall-cli 可执行文件", "Choose your locally built recall-cli executable")
        guard panel.runModal() == .OK, let executable = panel.url, FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let config: [String: Any] = ["mcpServers": ["Recall": ["command": executable.path, "args": ["mcp", "--data-dir", model.storage.rootURL.path], "env": ["RECALL_MCP_TOKEN": grant.token]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var binding: GlobalShortcutBinding
    let save: (GlobalShortcutBinding) -> Void
    func makeNSView(context: Context) -> ShortcutField { let v = ShortcutField(); updateNSView(v, context: context); return v }
    func updateNSView(_ view: ShortcutField, context: Context) { view.title = binding.label; view.changed = { binding = $0; save($0) } }
}
private final class ShortcutField: NSButton {
    var changed: ((GlobalShortcutBinding) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); bezelStyle = .rounded; target = self; action = #selector(beginRecording) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() { window?.makeFirstResponder(self); title = "⌘ / ⌃ + …" }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else { NSSound.beep(); return }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        changed?(GlobalShortcutBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)); window?.makeFirstResponder(nil)
    }
}
