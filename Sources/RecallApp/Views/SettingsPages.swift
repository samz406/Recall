import RecallKit
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EventRulesView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var selectedID: UUID?
    private var selected: EventRule? { model.state.rules.first { $0.id == selectedID } ?? model.state.rules.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecallPageHeader(title: "记录管理", subtitle: "选择何时记录、记录什么") {
                Button(RecallLocalization.text("查看已保存记录")) { if let source = model.state.captures.first { model.destination = .record(source.id) } }.disabled(model.state.captures.isEmpty)
            }
            HStack(spacing: 12) {
                RecallStatusBadge(title: "原图保留 " + retention(images: true))
                RecallStatusBadge(title: "文本保留 " + retention(images: false))
                RecallStatusBadge(title: model.state.rules.contains { $0.template == .enterKeyTrigger && $0.isEnabled } ? "裸 Enter 监听已启用" : "裸 Enter 监听关闭", warning: model.state.rules.contains { $0.template == .enterKeyTrigger && $0.isEnabled })
            }.padding(.horizontal, 24).padding(.bottom, 16)
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.state.rules) { rule in
                            HStack(spacing: 12) {
                                Button { selectedID = rule.id } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(rule.template.title).font(.system(size: 14, weight: .semibold))
                                        Text(rule.template.summary).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Toggle(RecallLocalization.text("启用") + rule.template.title, isOn: Binding(get: { model.state.rules.first { $0.id == rule.id }?.isEnabled ?? false }, set: { model.toggleRule(rule, isEnabled: $0) }))
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }.padding(14).background(selected?.id == rule.id ? RecallPalette.selected : RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected?.id == rule.id ? RecallPalette.accent : RecallPalette.border, lineWidth: 1))
                        }
                    }
                }.frame(width: 290).clipped()
                ScrollView {
                    if let selected {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(selected.template.title).font(RecallTypography.title)
                            Text(selected.template.summary).font(.callout).foregroundStyle(RecallPalette.secondary)
                            if selected.template == .enterKeyTrigger {
                                Label(model.enterKeyMonitorStatus.title, systemImage: model.enterKeyMonitorStatus.symbolName).font(.caption).foregroundStyle(RecallPalette.warning)
                                Text(RecallLocalization.text("仅在 Recall 不在前台时触发；不会拦截按键。需要输入监控、辅助功能和屏幕录制权限。")).font(.caption).foregroundStyle(RecallPalette.secondary)
                                Button(RecallLocalization.text("检查跨应用权限")) { model.checkEnterKeyMonitor() }
                            }
                            EventRuleEditor(rule: selected).id(selected.id)
                        }.recallSurface().padding(.bottom, 24)
                    }
                }.clipped()
            }.padding(.horizontal, 24).padding(.bottom, 16)
        }
    }
    private func retention(images: Bool) -> String {
        let values = model.state.rules.map { images ? $0.retainImageDays : $0.retainTextDays }
        let low = values.min() ?? 0, high = values.max() ?? 0
        return low == high ? "\(low) 天" : "\(low)–\(high) 天"
    }
}

private struct EventRuleRow: View {
    @EnvironmentObject private var model: RecallAppModel
    let rule: EventRule
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: Binding(
                    get: { model.state.rules.first(where: { $0.id == rule.id })?.isEnabled ?? false },
                    set: { model.toggleRule(rule, isEnabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.template.title).font(.headline)
                        Text(rule.template.summary).font(.caption).foregroundStyle(RecallPalette.secondary)
                    }
                }
                Button(expanded ? "收起" : "配置") { expanded.toggle() }
                    .buttonStyle(.borderless)
            }
            if rule.template == .enterKeyTrigger {
                HStack(spacing: 8) {
                    Label(model.enterKeyMonitorStatus.title, systemImage: model.enterKeyMonitorStatus.symbolName)
                        .font(.caption)
                        .foregroundStyle(model.enterKeyMonitorStatus == .monitoring ? RecallPalette.accent : RecallPalette.warning)
                    Spacer()
                    Button(RecallLocalization.text("检查跨应用权限")) {
                        model.checkEnterKeyMonitor()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Text(RecallLocalization.text("跨应用触发需同时获得“输入监控”和“辅助功能”授权；实际截图仍需屏幕录制权限。监听不拦截按键，且仅在 Recall 不在前台时触发。"))
                    .font(.caption2)
                    .foregroundStyle(RecallPalette.secondary)
            }
            if expanded {
                EventRuleEditor(rule: rule)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct EventRuleEditor: View {
    @EnvironmentObject private var model: RecallAppModel
    let rule: EventRule
    @State private var scope: CaptureScope
    @State private var retainImages: Int
    @State private var retainText: Int
    @State private var includeChat: Bool
    @State private var includeReminders: Bool
    @State private var allowList: String

    init(rule: EventRule) {
        self.rule = rule
        _scope = State(initialValue: rule.scope)
        _retainImages = State(initialValue: rule.retainImageDays)
        _retainText = State(initialValue: rule.retainTextDays)
        _includeChat = State(initialValue: rule.participatesInChat)
        _includeReminders = State(initialValue: rule.participatesInReminders)
        _allowList = State(initialValue: rule.appAllowList.joined(separator: ", "))
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text(RecallLocalization.text("采集范围"))
                Picker(RecallLocalization.text("采集范围"), selection: $scope) {
                    ForEach(CaptureScope.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            GridRow {
                Text(RecallLocalization.text("原图保留"))
                Stepper("\(retainImages) 天", value: $retainImages, in: 0...365).fixedSize()
            }
            GridRow {
                Text(RecallLocalization.text("文本保留"))
                Stepper("\(retainText) 天", value: $retainText, in: 1...3650).fixedSize()
            }
            GridRow {
                Text(RecallLocalization.text("应用白名单"))
                TextField(RecallLocalization.text("Bundle ID，以逗号分隔"), text: $allowList)
            }
        }
        Divider()
        RecallSwitchRow(title: "问一问可检索这类记录", isOn: $includeChat)
        RecallSwitchRow(title: "允许对这类记录手动深查待办", isOn: $includeReminders)
        Button(RecallLocalization.text("保存规则")) {
            var updated = model.state.rules.first { $0.id == rule.id } ?? rule
            updated.scope = scope
            updated.retainImageDays = retainImages
            updated.retainTextDays = retainText
            updated.participatesInChat = includeChat
            updated.participatesInReminders = includeReminders
            updated.appAllowList = allowList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            model.updateRule(updated)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct RecallDiagnosticsLogSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecallLocalization.text("本地诊断日志"))
                        .font(.title2.weight(.semibold))
                    Text(RecallLocalization.text("仅包含 Recall 的操作状态与错误代码，不包含 API Key、聊天正文、OCR 文本或截图。"))
                        .font(.caption)
                        .foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button(RecallLocalization.text("关闭")) { dismiss() }
            }
            .padding(20)

            Divider()

            if model.diagnosticEntries.isEmpty {
                ContentUnavailableView(RecallLocalization.text("暂无诊断记录"), systemImage: "stethoscope", description: Text(RecallLocalization.text("执行记录、Enter 监听或权限检查后，相关状态会显示在这里。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.diagnosticEntries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Image(systemName: symbol(for: entry.level))
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.level.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.source)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(RecallPalette.secondary)
                            Spacer()
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(RecallPalette.secondary)
                        }
                        Text(entry.message)
                            .font(.subheadline)
                        if !entry.metadata.isEmpty {
                            Text(entry.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(RecallPalette.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(RecallPalette.background)
            }

            Divider()
            HStack {
                Text(RecallLocalization.text("最多保留 200 条；仅保存在此 Mac。"))
                    .font(.caption)
                    .foregroundStyle(RecallPalette.secondary)
                Spacer()
                Button(RecallLocalization.text("清空日志"), role: .destructive) { model.clearDiagnosticLog() }
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
    }

    private func color(for level: RecallDiagnosticLevel) -> Color {
        switch level {
        case .info: RecallPalette.secondary
        case .warning: RecallPalette.warning
        case .error: RecallPalette.danger
        }
    }

    private func symbol(for level: RecallDiagnosticLevel) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

struct RecallSettingsView: View {
    var body: some View {
        PrivacyAndModelView()
            .padding()
    }
}

struct PrivacyAndModelView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var excludedApps = ""
    @State private var loaded = false
    @State private var savedKeyExists = false
    @State private var activeConfiguration = LLMConfiguration()
    @State private var isEditingModelConnection = false
    @State private var isShowingDiagnostics = false
    @State private var itemPendingPermanentDeletion: RecentlyDeletedMemory?
    @State private var isConfirmingPermanentDeletion = false
    @State private var isConfirmingClearAll = false
    @State private var showsAllRecentlyDeleted = false

    @State private var settingsCategory = "隐私与采集"
    @State private var showsMemorySettings = false
    @State private var showsDiagnosticSettings = false
    @State private var showsGovernance = false
    @State private var showsTime = false
    private let categories = ["使用偏好", "隐私与采集", "模型连接", "每日回顾", "记忆整理", "外观", "本地诊断"]

    init(initialCategory: String = "隐私与采集") { _settingsCategory = State(initialValue: initialCategory) }

    var body: some View {
        VStack(spacing: 0) {
            RecallPageHeader(title: "设置", subtitle: "管理本地数据边界、模型使用和每日回顾") { EmptyView() }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(categories, id: \.self) { value in
                        Button { settingsCategory = value } label: {
                            HStack(spacing: 8) {
                                Text(RecallLocalization.text(value)).font(.system(size: 14, weight: settingsCategory == value ? .semibold : .regular))
                            }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                                .foregroundStyle(settingsCategory == value ? RecallPalette.accent : RecallPalette.text)
                                .background(settingsCategory == value ? RecallPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }.frame(width: RecallLocalization.isEnglish ? 172 : 126)
                ScrollViewReader { proxy in
                    ScrollView {
                        if settingsCategory == "使用偏好" {
                            WorkflowSettingsView().padding(.bottom, 24)
                        } else if settingsCategory == "外观" {
                            AppearanceSettingsView().padding(.bottom, 24)
                        } else {
                        VStack(alignment: .leading, spacing: 14) {
                            privacyStatus
                            privacyCard.id("隐私与采集")
                            modelCard.id("模型连接")
                            dailyCard.id("每日回顾")
                            DisclosureGroup(isExpanded: $showsMemorySettings) {
                                VStack(alignment: .leading, spacing: 18) {
                                    CaptureUnderstandingSettingsView().environmentObject(model)
                                    Divider()
                                    MemoryOrganizationSettings().environmentObject(model)
                                    Divider()
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(RecallLocalization.text("回顾纠正")).font(.subheadline.weight(.medium))
                                            Text(RecallLocalization.text("查看纠正记录，撤销更改或停用写作偏好。"))
                                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                                        }
                                        Spacer(minLength: 12)
                                        Button(RecallLocalization.text("管理纠正记录")) { model.showsSummaryFeedbackHistory = true }
                                    }
                                }.padding(.top, 16)
                            } label: {
                                HStack { Text(RecallLocalization.text("记忆整理")).fontWeight(.semibold); Spacer(); Text(model.state.memoryKnowledgeSettings.automaticOrganization ? "后台整理已开启" : "后台整理已暂停").font(.caption).foregroundStyle(RecallPalette.secondary) }
                            }.recallSurface().id("记忆整理")
                            DisclosureGroup(isExpanded: $showsDiagnosticSettings) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(RecallLocalization.text("仅记录操作结果、权限状态和错误代码，不包含聊天正文、识别文字、截图或密钥。")).font(.caption).foregroundStyle(RecallPalette.secondary)
                                    Button(RecallLocalization.text("查看日志")) { isShowingDiagnostics = true }
                                }.padding(.top, 12)
                            } label: {
                                HStack { Text(RecallLocalization.text("本地诊断")).fontWeight(.semibold); Spacer(); Text("当前 \(model.diagnosticEntries.count) 条").font(.caption).foregroundStyle(RecallPalette.secondary) }
                            }.recallSurface().id("本地诊断")
                            LocalArchiveSafetyCard().environmentObject(model)
                            DisclosureGroup(RecallLocalization.text("最近删除与忽略规则"), isExpanded: $showsGovernance) { memoryGovernanceSection.padding(.top, 14) }.recallSurface()
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(RecallLocalization.text("清空本地记忆")).font(.subheadline.weight(.medium))
                                    Text(RecallLocalization.text("清空全部内容后无法恢复。")).font(.caption).foregroundStyle(RecallPalette.secondary)
                                }
                                Spacer()
                                Button(RecallLocalization.text("删除全部本地记忆"), role: .destructive) { isConfirmingClearAll = true }.disabled(model.isClearingAllData)
                            }.padding(16)
                        }.padding(.bottom, 24)
                        }
                    }.clipped().onChange(of: settingsCategory) { _, category in
                        if category == "记忆整理" { showsMemorySettings = true }
                        if category == "本地诊断" { showsDiagnosticSettings = true }
                        if category != "外观" { withAnimation { proxy.scrollTo(category, anchor: .top) } }
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 16)
        }
        .toggleStyle(.switch).controlSize(.small)
        .background(RecallPalette.background)
        .onAppear(perform: load)
        .sheet(isPresented: $isShowingDiagnostics) {
            RecallDiagnosticsLogSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $isEditingModelConnection) {
            ModelConnectionEditorSheet(
                configuration: activeConfiguration,
                savedKeyExists: savedKeyExists
            ) { configuration, key in
                let excluded = model.state.privacy.excludedBundleIdentifiers
                activeConfiguration = configuration
                model.saveModelConnection(configuration: configuration, apiKey: key, excludedBundleIdentifiers: excluded)
                if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    savedKeyExists = true
                }
            }
        }
        .confirmationDialog(
            "永久删除后无法恢复",
            isPresented: $isConfirmingPermanentDeletion,
            presenting: itemPendingPermanentDeletion
        ) { item in
            Button("永久删除“\(item.label)”", role: .destructive) { model.permanentlyDelete(item) }
            Button(RecallLocalization.text("取消"), role: .cancel) {}
        } message: { _ in
            Text(RecallLocalization.text("关联截图和最近删除快照会从这台 Mac 上清除。"))
        }
        .confirmationDialog("永久清空全部本地记忆？", isPresented: $isConfirmingClearAll) {
            Button(RecallLocalization.text("永久清空"), role: .destructive) { model.clearAllData() }
            Button(RecallLocalization.text("取消"), role: .cancel) {}
        } message: {
            Text(RecallLocalization.text("时间线、问一问、总结、提醒、长期记忆、截图、最近删除和忽略规则都会清除，且无法撤销。设置会保留。"))
        }
    }

    private var privacyStatus: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { privacyStatusText; Spacer(minLength: 8); pauseButton }
            VStack(alignment: .leading, spacing: 12) { privacyStatusText; pauseButton }
        }.padding(16).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
    }
    private var privacyStatusText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(model.state.privacy.screenCapturePaused ? "采集已暂停" : "采集由你控制 · 记录保存在本机", systemImage: model.state.privacy.screenCapturePaused ? "pause.circle" : "lock.shield")
                .font(.subheadline.weight(.medium))
            Text(model.state.privacy.cloudUseEnabled ? "已允许向连接的模型发送脱敏文本" : "云端模型已关闭，文本不外发")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
        }
    }
    private var pauseButton: some View {
        Button(model.state.privacy.screenCapturePaused ? "恢复采集" : "暂停全部采集") {
            var privacy = model.state.privacy; privacy.screenCapturePaused.toggle(); model.updatePrivacy(privacy)
        }.fixedSize()
    }
    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(RecallLocalization.text("屏幕与数据")).font(.headline).foregroundStyle(RecallPalette.accent)
            RecallSwitchRow(title: "保留原始截图", detail: "按记录管理中设置的周期清理。关闭后仅保留识别文字。", isOn: privacyBinding(\.retainScreenshots))
            Text(RecallLocalization.text("排除的应用（不会被采集）")).font(.caption).foregroundStyle(RecallPalette.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(model.state.privacy.excludedBundleIdentifiers.sorted(), id: \.self) { id in
                    HStack(spacing: 6) {
                        Text(applicationName(id)).font(.caption).lineLimit(1)
                        Button { var privacy = model.state.privacy; privacy.excludedBundleIdentifiers.remove(id); model.updatePrivacy(privacy) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).accessibilityLabel("不再排除" + applicationName(id))
                    }.padding(.horizontal, 9).padding(.vertical, 7).background(RecallPalette.selected, in: Capsule()).help(id)
                }
                Button(RecallLocalization.text("＋ 添加")) { addExcludedApplication() }.buttonStyle(.borderless)
            }
            Button(RecallLocalization.text("检查屏幕权限")) { model.requestScreenRecordingAccess() }.buttonStyle(.plain).font(.caption).foregroundStyle(RecallPalette.accent)
        }.recallSurface()
    }
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(RecallLocalization.text("模型连接")).font(.headline).foregroundStyle(RecallPalette.accent)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cpu").foregroundStyle(RecallPalette.accent).frame(width: 36, height: 36).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.state.llmConfiguration.provider.title).font(.subheadline.weight(.medium))
                    Text(model.state.llmConfiguration.model).font(.caption)
                    Text(model.state.llmConfiguration.baseURLString).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(1).textSelection(.enabled)
                    Text(!model.state.llmConfiguration.hasCredential ? "尚未配置凭据" : "连接已配置 · 凭据仅保存在本机").font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                Spacer(minLength: 0)
                Button(RecallLocalization.text("删除凭据"), role: .destructive) { model.deleteModelKey() }
                Button(RecallLocalization.text("编辑")) { activeConfiguration = model.state.llmConfiguration; savedKeyExists = activeConfiguration.hasCredential; isEditingModelConnection = true }
            }
            RecallSwitchRow(title: "允许发送脱敏文本", detail: "关闭后，问一问使用本地摘录；模型回顾和自动理解会暂停。", isOn: privacyBinding(\.cloudUseEnabled))
        }.recallSurface()
    }
    private var dailyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(RecallLocalization.text("每日回顾")).font(.headline).foregroundStyle(RecallPalette.accent)
            RecallSwitchRow(title: "每天自动汇总前一天", detail: "只回顾已保存的记录，需连接模型并允许发送脱敏文本。", isOn: dailySummaryEnabledBinding)
            HStack {
                Text(RecallLocalization.text("生成时间")).font(.subheadline)
                Spacer()
                Button(String(format: "每天 %02d:%02d ▾", model.state.dailySummarySettings.hour, model.state.dailySummarySettings.minute)) { showsTime = true }
                    .popover(isPresented: $showsTime) {
                        VStack(alignment: .leading, spacing: 16) {
                            DatePicker("每天生成时间", selection: dailySummaryTimeBinding, displayedComponents: .hourAndMinute).datePickerStyle(.field)
                            Button(RecallLocalization.text("完成")) { showsTime = false }
                        }.padding(20)
                    }.disabled(!model.state.dailySummarySettings.isEnabled)
            }
            RecallSwitchRow(title: "完成后发送系统通知", detail: "主动开启后才请求通知权限。", isOn: dailySummaryNotificationBinding).disabled(!model.state.dailySummarySettings.isEnabled)
        }.recallSurface()
    }
    private func applicationName(_ id: String) -> String {
        let known = ["com.apple.MobileSMS": "信息", "com.apple.Passwords": "密码", "com.apple.keychainaccess": "钥匙串访问"]
        if let name = known[id] { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url.deletingPathExtension().lastPathComponent }
        return id.split(separator: ".").last.map(String.init) ?? id
    }
    private func addExcludedApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowsMultipleSelection = true
        panel.prompt = "排除这些应用"
        guard panel.runModal() == .OK else { return }
        var privacy = model.state.privacy
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { privacy.excludedBundleIdentifiers.insert(id) } }
        model.updatePrivacy(privacy)
    }

    private var memoryGovernanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(RecallLocalization.text("记忆治理"), systemImage: "trash.slash")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("最近删除保留 \(MemoryGovernance.retentionDays) 天")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.secondary)
            }
            Text(RecallLocalization.text("删除的内容会立即退出搜索、问一问、总结和派生提醒；7 天内可恢复。到期时运行中的应用会自动清理，应用关闭时将在下次启动后清理。忽略规则只保存在本机，并在采集时生效。"))
                .font(.subheadline)
                .foregroundStyle(RecallPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.state.recentlyDeletedMemories.isEmpty && model.state.memorySuppressionRules.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(RecallPalette.accent)
                    Text(RecallLocalization.text("暂无最近删除内容或忽略规则。"))
                        .font(.subheadline)
                        .foregroundStyle(RecallPalette.secondary)
                }
                .padding(.vertical, 4)
            } else {
                if !model.state.recentlyDeletedMemories.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(RecallLocalization.text("最近删除")).font(.headline)
                            Text("\(model.state.recentlyDeletedMemories.count) 条")
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                            Spacer()
                            if model.state.recentlyDeletedMemories.count > 8 {
                                Button(showsAllRecentlyDeleted ? "收起" : "查看全部") {
                                    showsAllRecentlyDeleted.toggle()
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        LazyVStack(spacing: 10) {
                            ForEach(model.state.recentlyDeletedMemories
                                .sorted { $0.deletedAt > $1.deletedAt }
                                .prefix(showsAllRecentlyDeleted ? model.state.recentlyDeletedMemories.count : 8)) { item in
                                HStack(spacing: 12) {
                                    Image(systemName: "trash.circle")
                                        .foregroundStyle(RecallPalette.warning)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.label).font(.subheadline.weight(.medium)).lineLimit(1)
                                        Text(item.reason.title)
                                            .font(.caption).foregroundStyle(RecallPalette.secondary)
                                        Text(item.expiresAt <= .now
                                             ? "已到期，等待永久清理"
                                             : "将于 \(item.expiresAt.formatted(date: .abbreviated, time: .shortened)) 永久删除")
                                            .font(.caption).foregroundStyle(RecallPalette.secondary)
                                    }
                                    Spacer()
                                    Button(RecallLocalization.text("恢复")) { model.restoreRecentlyDeleted(item) }
                                        .buttonStyle(.bordered)
                                        .disabled(item.expiresAt <= .now)
                                    Button(RecallLocalization.text("永久删除"), role: .destructive) {
                                        itemPendingPermanentDeletion = item
                                        isConfirmingPermanentDeletion = true
                                    }
                                        .buttonStyle(.borderless)
                                }
                                .padding(12)
                                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }

                if !model.state.memorySuppressionRules.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(RecallLocalization.text("以后忽略")).font(.headline)
                        ForEach(model.state.memorySuppressionRules.filter(\.isEnabled).prefix(8)) { rule in
                            HStack(spacing: 12) {
                                Image(systemName: "nosign").foregroundStyle(RecallPalette.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.phrase).font(.subheadline).lineLimit(1)
                                    Text(rule.reason.title).font(.caption).foregroundStyle(RecallPalette.secondary)
                                }
                                Spacer()
                                Button(RecallLocalization.text("删除规则"), role: .destructive) { model.removeSuppressionRule(rule) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RecallPalette.border, lineWidth: 1))
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(RecallPalette.onAccent)
                .frame(width: 50, height: 50)
                .background(RecallPalette.accent, in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text(RecallLocalization.text("设置"))
                    .font(.system(size: 26, weight: .semibold))
                Text(RecallLocalization.text("统一管理本地数据边界、模型使用和每日回顾。"))
                    .font(.subheadline)
                    .foregroundStyle(RecallPalette.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Label(model.state.privacy.screenCapturePaused ? "采集已暂停" : "本地数据保护中", systemImage: model.state.privacy.screenCapturePaused ? "pause.circle.fill" : "lock.fill")
                Label(model.state.privacy.cloudUseEnabled ? "已允许脱敏文本" : "仅本地模式", systemImage: model.state.privacy.cloudUseEnabled ? "cloud.fill" : "desktopcomputer")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(RecallPalette.secondary)
        }
        .padding(20)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RecallPalette.border, lineWidth: 1))
    }

    private func settingsCard<Content: View>(title: String, icon: String, tint: Color = .accentColor, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            content()
        }
        .padding(20)
        .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(RecallPalette.border, lineWidth: 1))
    }

    private func load() {
        guard !loaded else { return }
        let savedConfiguration = model.state.llmConfiguration
        activeConfiguration = savedConfiguration
        excludedApps = model.state.privacy.excludedBundleIdentifiers.sorted().joined(separator: ", ")
        savedKeyExists = savedConfiguration.hasCredential
        loaded = true
    }


    private var dailySummaryEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.state.dailySummarySettings.isEnabled },
            set: { value in
                var settings = model.state.dailySummarySettings
                settings.isEnabled = value
                model.updateDailySummarySettings(settings)
            }
        )
    }

    private var dailySummaryTimeBinding: Binding<Date> {
        Binding(
            get: {
                let settings = model.state.dailySummarySettings
                return Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: .now) ?? .now
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                var settings = model.state.dailySummarySettings
                settings.hour = components.hour ?? settings.hour
                settings.minute = components.minute ?? settings.minute
                model.updateDailySummarySettings(settings)
            }
        )
    }

    private var dailySummaryNotificationBinding: Binding<Bool> {
        Binding(
            get: { model.state.dailySummarySettings.notifyWhenReady ?? false },
            set: { value in
                var settings = model.state.dailySummarySettings
                settings.notifyWhenReady = value
                model.updateDailySummarySettings(settings)
            }
        )
    }

    private func privacyBinding(_ keyPath: WritableKeyPath<PrivacySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.state.privacy[keyPath: keyPath] },
            set: { value in
                var privacy = model.state.privacy
                privacy[keyPath: keyPath] = value
                model.updatePrivacy(privacy)
            }
        )
    }
}
