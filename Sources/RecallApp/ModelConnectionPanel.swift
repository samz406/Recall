import AppKit
import RecallKit

/// 与主界面滚动布局隔离的原生编辑窗口，避免配置输入受到 SwiftUI 刷新影响。
@MainActor
final class ModelConnectionPanel: NSWindowController, NSWindowDelegate {
    private static var activeController: ModelConnectionPanel?

    private let initialConfiguration: LLMConfiguration
    private let providerControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let savedKeyExists: Bool
    private let onSave: (LLMConfiguration, String) -> Void

    static func present(
        configuration: LLMConfiguration,
        savedKeyExists: Bool,
        onSave: @escaping (LLMConfiguration, String) -> Void
    ) {
        activeController?.close()
        let controller = ModelConnectionPanel(
            configuration: configuration,
            savedKeyExists: savedKeyExists,
            onSave: onSave
        )
        activeController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(configuration: LLMConfiguration, savedKeyExists: Bool, onSave: @escaping (LLMConfiguration, String) -> Void) {
        self.initialConfiguration = configuration
        self.savedKeyExists = savedKeyExists
        self.onSave = onSave

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "编辑模型连接"
        panel.isReleasedWhenClosed = false
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        if Self.activeController === self {
            Self.activeController = nil
        }
    }

    private func buildContent(in panel: NSPanel) {
        let contentView = NSView()
        panel.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24)
        ])

        let title = NSTextField(labelWithString: "模型连接")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)

        let description = NSTextField(wrappingLabelWithString: "在这里直接填写服务地址、模型名称和 API Key。保存后，下一次“问一问”将使用该连接。")
        description.textColor = .secondaryLabelColor
        stack.addArrangedSubview(description)

        configureProviderControl()
        stack.addArrangedSubview(fieldGroup(title: "模型类型", control: providerControl))

        baseURLField.stringValue = initialConfiguration.baseURLString
        baseURLField.placeholderString = "例如：https://api.minimaxi.com/anthropic"
        configureEditableField(baseURLField)
        stack.addArrangedSubview(fieldGroup(title: "API 地址", control: baseURLField))

        modelField.stringValue = initialConfiguration.model
        modelField.placeholderString = "例如：MiniMax-M3.0"
        configureEditableField(modelField)
        stack.addArrangedSubview(fieldGroup(title: "模型名称", control: modelField))

        apiKeyField.placeholderString = savedKeyExists ? "输入新 Key 以替换已保存凭据" : "粘贴 API Key"
        configureEditableField(apiKeyField)
        let keyGroup = fieldGroup(title: savedKeyExists ? "API Key（已保存，输入新值可替换）" : "API Key", control: apiKeyField)
        stack.addArrangedSubview(keyGroup)

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        let hint = NSTextField(labelWithString: "API Key 仅存入本机 Keychain，不会写入项目文件。")
        hint.textColor = .secondaryLabelColor
        buttons.addArrangedSubview(hint)
        buttons.addArrangedSubview(NSView())
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        let saveButton = NSButton(title: "保存并用于问一问", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            baseURLField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            apiKeyField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func configureProviderControl() {
        providerControl.addItems(withTitles: ["兼容 OpenAI API", "兼容 Anthropic API"])
        providerControl.selectItem(at: initialConfiguration.provider == .anthropicCompatible ? 1 : 0)
        providerControl.target = self
        providerControl.action = #selector(providerChanged)
    }

    private func configureEditableField(_ field: NSTextField) {
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.focusRingType = .default
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 14)
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func fieldGroup(title: String, control: NSView) -> NSStackView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        group.addArrangedSubview(label)
        group.addArrangedSubview(control)
        return group
    }

    @objc private func providerChanged() {
        let provider: LLMProviderKind = providerControl.indexOfSelectedItem == 1 ? .anthropicCompatible : .openAICompatible
        baseURLField.stringValue = provider.defaultBaseURL
        modelField.stringValue = provider.defaultModel
        baseURLField.becomeFirstResponder()
    }

    @objc private func cancel() {
        close()
    }

    @objc private func save() {
        let provider: LLMProviderKind = providerControl.indexOfSelectedItem == 1 ? .anthropicCompatible : .openAICompatible
        let baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !model.isEmpty else {
            NSSound.beep()
            baseURLField.becomeFirstResponder()
            return
        }
        let configuration = LLMConfiguration(
            provider: provider,
            baseURLString: baseURL,
            model: model,
            keychainAccount: initialConfiguration.keychainAccount,
            anthropicVersion: initialConfiguration.anthropicVersion,
            maxOutputTokens: initialConfiguration.maxOutputTokens
        )
        onSave(configuration, apiKeyField.stringValue)
        close()
    }
}
