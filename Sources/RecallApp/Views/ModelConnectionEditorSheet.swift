import SwiftUI
import RecallKit
import AppKit

/// Keeps a successful test tied to the exact draft, never to a later edit.
@MainActor
final class ModelConnectionDraft: ObservableObject {
    enum TestState: Equatable { case idle, testing, success, failure(String) }
    let initialConfiguration: LLMConfiguration
    let savedKeyExists: Bool
    @Published var provider: LLMProviderKind {
        didSet {
            guard provider != oldValue else { return }
            baseURL = provider.defaultBaseURL; modelName = provider.defaultModel; invalidateTest()
        }
    }
    @Published var baseURL: String { didSet { if baseURL != oldValue { invalidateTest() } } }
    @Published var modelName: String { didSet { if modelName != oldValue { invalidateTest() } } }
    @Published var apiKey = "" { didSet { if apiKey != oldValue { invalidateTest() } } }
    @Published private(set) var testState: TestState = .idle
    private var testTask: Task<Void, Never>?
    private var testID: UUID?

    init(configuration: LLMConfiguration, savedKeyExists: Bool) {
        initialConfiguration = configuration
        self.savedKeyExists = savedKeyExists && !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        provider = configuration.provider == .anthropicCompatible ? .anthropicCompatible : .openAICompatible
        baseURL = configuration.baseURLString; modelName = configuration.model
        // Never populate either the visible or secure input with the persisted credential.
    }
    var normalizedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var effectiveAPIKey: String { normalizedAPIKey.isEmpty ? initialConfiguration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) : normalizedAPIKey }
    var configuration: LLMConfiguration {
        LLMConfiguration(provider: provider, baseURLString: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), model: modelName.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: effectiveAPIKey, anthropicVersion: initialConfiguration.anthropicVersion, maxOutputTokens: initialConfiguration.maxOutputTokens)
    }
    var hasValidEndpoint: Bool {
        guard let url = URL(string: configuration.baseURLString),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !configuration.model.isEmpty else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }
    var connectionChanged: Bool { configuration != initialConfiguration || !normalizedAPIKey.isEmpty }
    var isTesting: Bool { testState == .testing }
    var canTest: Bool { hasValidEndpoint && !effectiveAPIKey.isEmpty && !isTesting }
    var canSave: Bool { hasValidEndpoint && !effectiveAPIKey.isEmpty && !isTesting && ((!connectionChanged && savedKeyExists) || testState == .success) }
    func invalidateTest() {
        testID = nil; testTask?.cancel(); testTask = nil; testState = .idle
    }
    func test(using tester: @escaping @Sendable (LLMConfiguration) async throws -> Void = { configuration in
        _ = try await CompatibleLLM(configuration: configuration, apiKey: configuration.apiKey)
            .answerCancellably(to: LLMRequest(question: "仅回复连接成功", context: []))
    }) {
        guard canTest else { return }
        invalidateTest()
        let id = UUID(), request = configuration
        testID = id; testState = .testing
        testTask = Task { [weak self] in
            do {
                try await tester(request)
                guard !Task.isCancelled, let self, self.testID == id else { return }
                self.testState = .success; self.testTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.testID == id else { return }
                // No raw server response, URL credentials or typed/saved secret reaches the UI.
                let message = Self.failureMessage(error)
                self.testState = .failure(message); self.testTask = nil
            }
        }
    }
    private static func failureMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时，请稍后重试"
            case .notConnectedToInternet, .networkConnectionLost: return "网络未连接，请检查网络"
            case .cannotFindHost, .cannotConnectToHost: return "无法连接 API 地址，请检查服务地址"
            default: return "网络或证书异常，请检查服务地址"
            }
        }
        if let llmError = error as? LLMError {
            switch llmError {
            case .missingAPIKey: return "请填写 API Key"
            case .invalidBaseURL: return "API 地址无效"
            case .invalidResponse: return "服务响应格式不兼容，请检查接口协议"
            case .serviceError(let message):
                if message.contains("401") || message.contains("403") { return "认证失败，请检查 API Key 和服务权限" }
                if message.contains("429") { return "服务请求受限，请稍后重试" }
                if message.contains("404") { return "接口或模型不存在，请检查地址、协议和模型名称" }
                return "服务请求失败，请检查协议、模型名称和凭据"
            }
        }
        return "连接未成功，请检查地址、协议、模型名称和凭据"
    }
}

struct ModelConnectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: ModelConnectionDraft
    @State private var revealsAPIKey = false
    @FocusState private var focusedField: Field?
    let onSave: (LLMConfiguration, String) -> Void
    private enum Field: Hashable { case baseURL, model, apiKey }

    init(configuration: LLMConfiguration, savedKeyExists: Bool, onSave: @escaping (LLMConfiguration, String) -> Void) {
        _draft = StateObject(wrappedValue: ModelConnectionDraft(configuration: configuration, savedKeyExists: savedKeyExists))
        self.onSave = onSave
    }
    // Internal initializer for synthetic native layout checks; never makes a live request.
    init(draft: ModelConnectionDraft, onSave: @escaping (LLMConfiguration, String) -> Void = { _, _ in }) {
        _draft = StateObject(wrappedValue: draft); self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(RecallPalette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 21) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("接口协议").font(.system(size: 14, weight: .semibold))
                        protocolControl
                    }
                    connectionField("API 地址") {
                        TextField(draft.provider.defaultBaseURL, text: $draft.baseURL).focused($focusedField, equals: .baseURL)
                    }
                    connectionField("模型名称") {
                        TextField(draft.provider.defaultModel, text: $draft.modelName).focused($focusedField, equals: .model)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        connectionField("API Key") {
                            HStack(spacing: 10) {
                                ZStack(alignment: .leading) {
                                    if draft.apiKey.isEmpty && draft.savedKeyExists {
                                        Text("已保存 · 留空则继续使用").foregroundStyle(RecallPalette.secondary).allowsHitTesting(false)
                                    }
                                    Group {
                                        if revealsAPIKey { TextField(draft.savedKeyExists ? "" : "输入 API Key", text: $draft.apiKey) }
                                        else { SecureField(draft.savedKeyExists ? "" : "输入 API Key", text: $draft.apiKey) }
                                    }.focused($focusedField, equals: .apiKey)
                                        .accessibilityLabel("API Key")
                                }
                                Button {
                                    revealsAPIKey.toggle(); focusedField = .apiKey
                                } label: { Image(systemName: revealsAPIKey ? "eye.slash" : "eye").foregroundStyle(RecallPalette.secondary) }
                                    .buttonStyle(.plain).help(revealsAPIKey ? "隐藏输入的 API Key" : "显示输入的 API Key")
                                    .accessibilityLabel(revealsAPIKey ? "隐藏输入的 API Key" : "显示输入的 API Key")
                            }
                        }
                        Label("Key 只保存在本机，重新打开时不会显示", systemImage: "lock")
                            .font(.caption).foregroundStyle(RecallPalette.secondary)
                    }
                    testStrip
                }.padding(26)
            }.clipped()
            Divider().overlay(RecallPalette.border)
            HStack(spacing: 18) {
                Label("保存后，下一次提问立即使用新连接", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                Spacer(minLength: 8)
                Button("取消", action: close).buttonStyle(.plain).keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard draft.canSave else { return }
                    onSave(draft.configuration, draft.normalizedAPIKey); close()
                }.buttonStyle(EditorButtonStyle(prominent: true)).disabled(!draft.canSave).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 26).padding(.vertical, 18)
        }.frame(width: 700, height: min(744, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
            .background(RecallPalette.surface)
            .recallColors()
            .onDisappear { draft.invalidateTest() }
    }
    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "cpu").font(.system(size: 22, weight: .medium))
                .foregroundStyle(RecallPalette.accent).frame(width: 48, height: 48)
                .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text("编辑模型连接").font(.system(size: 21, weight: .semibold))
                Text("配置与 OpenAI 或 Anthropic 协议兼容的模型服务")
                    .font(.system(size: 13)).foregroundStyle(RecallPalette.secondary)
            }
            Spacer(minLength: 4)
            if draft.savedKeyExists {
                Label("凭据已配置", systemImage: "checkmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RecallPalette.accent).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RecallPalette.selected, in: Capsule()).fixedSize()
            }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 16)).foregroundStyle(RecallPalette.secondary).frame(width: 26, height: 30) }
                .buttonStyle(.plain).accessibilityLabel("关闭模型连接")
        }.padding(26)
    }
    private var protocolControl: some View {
        HStack(spacing: 4) {
            ForEach([LLMProviderKind.openAICompatible, .anthropicCompatible]) { provider in
                Button { draft.provider = provider } label: {
                    Text(provider.title).font(.system(size: 14, weight: draft.provider == provider ? .semibold : .regular))
                        .foregroundStyle(draft.provider == provider ? RecallPalette.accent : RecallPalette.secondary)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(draft.provider == provider ? RecallPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .shadow(color: draft.provider == provider ? .black.opacity(0.06) : .clear, radius: 2, y: 1)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityAddTraits(draft.provider == provider ? .isSelected : [])
            }
        }.padding(4).background(RecallPalette.background, in: RoundedRectangle(cornerRadius: 12))
    }
    private func connectionField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content().textFieldStyle(.plain).font(.system(size: 15))
                .padding(.horizontal, 16).frame(height: 48).frame(maxWidth: .infinity, alignment: .leading)
                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecallPalette.border, lineWidth: 1))
        }
    }
    private var testStrip: some View {
        HStack(spacing: 14) {
            if draft.isTesting { ProgressView().controlSize(.small).frame(width: 12) }
            else { Circle().fill(statusColor).frame(width: 8, height: 8) }
            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitle).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text("测试不会发送本地记忆").font(.caption).foregroundStyle(RecallPalette.secondary)
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            if draft.isTesting {
                Button("取消测试") { draft.invalidateTest() }.buttonStyle(EditorButtonStyle())
            } else {
                Button { draft.test() } label: { Label("测试连接", systemImage: "waveform.path.ecg") }
                    .buttonStyle(EditorButtonStyle()).disabled(!draft.canTest)
            }
        }.padding(18).background(RecallPalette.background, in: RoundedRectangle(cornerRadius: 12))
    }
    private var statusTitle: String {
        switch draft.testState {
        case .idle: "尚未测试连接"
        case .testing: "正在测试连接…"
        case .success: "连接正常"
        case .failure(let reason): "失败：" + reason
        }
    }
    private var statusColor: Color {
        switch draft.testState { case .success: RecallPalette.accent; case .failure: RecallPalette.danger; default: RecallPalette.secondary.opacity(0.6) }
    }
    private func close() { draft.invalidateTest(); dismiss() }
}

private struct EditorButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, prominent ? 24 : 18).frame(height: 42)
            .foregroundStyle(prominent ? RecallPalette.onAccent : RecallPalette.accent)
            .background(prominent ? RecallPalette.accent : RecallPalette.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(RecallPalette.accent, lineWidth: prominent ? 0 : 1))
            .opacity(!enabled ? 0.45 : (configuration.isPressed ? 0.8 : 1))
    }
}
