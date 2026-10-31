import SwiftUI
import RecallKit

struct SummaryFeedbackFooter: View {
    @EnvironmentObject private var model: RecallAppModel
    let target: SummaryFeedbackTarget
    var showsFeedbackButton = true
    private var latest: SummaryFeedback? { model.state.summaryFeedback.last { $0.target.reportID == target.reportID && $0.state != .withdrawn } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                if showsFeedbackButton {
                    Button { model.summaryFeedbackTarget = target } label: { Label("反馈", systemImage: "bubble.left") }
                        .buttonStyle(.borderless)
                }
                Button("反馈记录与偏好") { model.showsSummaryFeedbackHistory = true }.buttonStyle(.borderless)
                Spacer(minLength: 0)
            }
            if let latest {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: latest.state == .applied ? "checkmark.circle" : "info.circle")
                    Text(latest.message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if latest.state == .applied { Button("撤销") { model.withdrawFeedback(latest.id) } }
                }.foregroundStyle(RecallPalette.secondary)
            }
        }.font(.caption).padding(.top, 6)
    }
}

struct SummaryFeedbackSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let target: SummaryFeedbackTarget
    @State private var text = ""
    @State private var saving = false
    @FocusState private var focused: Bool
    private let examples = ["事实不对：", "漏了内容：", "这不是待办：", "表达可以改为："]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("让这份回顾更准确").font(.title2.weight(.semibold))
                    Text(target.title).font(.caption).foregroundStyle(RecallPalette.secondary).lineLimit(2)
                }
                Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).disabled(saving)
            }
            if let item = target.items.first, target.itemID != nil {
                Text(item.title).font(.headline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("哪里不对，或你希望怎么改？").font(.headline)
            HStack(spacing: 10) {
                ForEach(examples, id: \.self) { example in
                    Button(example.replacingOccurrences(of: "：", with: "")) { if text.isEmpty { text = example }; focused = true }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            TextEditor(text: $text).font(RecallTypography.body).scrollContentBackground(.hidden)
                .padding(10).frame(height: 140).focused($focused)
                .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecallPalette.border))
            Text("说明实际情况会更有帮助。想让后续回顾也这样写，可以加上“以后”。")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            HStack {
                Text("\(text.count)/1200").font(.caption).foregroundStyle(RecallPalette.secondary)
                Spacer()
                Button("取消") { dismiss() }.disabled(saving)
                Button(saving ? "正在保存…" : "提交反馈") {
                    saving = true
                    Task {
                        if await model.sendSummaryFeedback(target, text: text) { dismiss() }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || text.count > 1_200)
            }
        }.padding(28).frame(width: 620).background(RecallPalette.background).interactiveDismissDisabled(saving)
            .onAppear { focused = true }
    }
}

struct SummaryFeedbackHistoryView: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var visible = 20
    @State private var showSettings = false
    @State private var onlyRules = false
    private var entries: [SummaryFeedback] {
        model.state.summaryFeedback.reversed().filter { !onlyRules || ($0.state == .applied && !($0.resolution?.rules.isEmpty ?? true)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecallPageHeader(title: "反馈与总结偏好", subtitle: "查看改了什么，也可以撤销或停止使用") { Button("完成") { dismiss() } }
            Divider()
            HStack {
                Picker("查看", selection: $onlyRules) { Text("反馈记录").tag(false); Text("总结偏好").tag(true) }
                    .pickerStyle(.segmented).frame(width: 220)
                Spacer()
                Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).help("反馈处理设置")
            }.padding(.horizontal, 24).padding(.vertical, 16)
            if showSettings {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("在后台处理我提交的反馈", isOn: Binding(get: { model.state.summaryFeedbackSettings.processingEnabled }, set: {
                        var settings = model.state.summaryFeedbackSettings; settings.processingEnabled = $0; model.updateFeedbackSettings(settings)
                    }))
                    Toggle("后续回顾使用总结偏好", isOn: Binding(get: { model.state.summaryFeedbackSettings.useLearnedRules }, set: {
                        var settings = model.state.summaryFeedbackSettings; settings.useLearnedRules = $0; model.updateFeedbackSettings(settings)
                    }))
                    Text("只处理你提交的反馈。应用关闭时暂停，下次启动后继续；模型文本使用仍遵循设置中的隐私选项。")
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                }.padding(18).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24).padding(.bottom, 16)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(onlyRules ? "暂时没有总结偏好" : "还没有反馈记录").font(.headline)
                            Text(onlyRules ? "明确提出“以后怎么写”后，适用范围和要求会显示在这里。" : "在每日回顾或周期回顾下方提交反馈，调整结果会保存在这里。")
                                .font(.callout).foregroundStyle(RecallPalette.secondary)
                        }.padding(.vertical, 28)
                    }
                    ForEach(Array(entries.prefix(visible))) { entry in feedbackRow(entry) }
                    if entries.count > visible { Button("再显示 20 条") { visible += 20 } }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }.clipped()
        }.frame(width: 760, height: 640).background(RecallPalette.background)
    }
    private func feedbackRow(_ entry: SummaryFeedback) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.target.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(entry.createdAt.formatted()).font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Text(entry.state.title).font(.caption.weight(.medium)).foregroundStyle(entry.state == .applied ? RecallPalette.accent : RecallPalette.secondary)
            }
            Text(entry.text).font(RecallTypography.body).textSelection(.enabled)
            Text(entry.message).font(.callout).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            if let resolution = entry.resolution {
                ForEach(resolution.rules) { rule in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(rule.kind.instruction).font(.callout)
                            Text(rule.allReviews ? "适用于所有回顾" : ((entry.target.kind == .daily ? "适用于每日回顾" : "适用于 " + (entry.weeklyBefore?.template.name ?? "本类周期回顾")) + (rule.topicID == nil ? "" : "中的这件事")))
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                        }
                        Spacer()
                        if entry.state == .applied && !entry.disabledRuleIDs.contains(rule.id) {
                            Button("停用") { model.disableFeedbackRule(entry.id, rule: rule.id) }.font(.caption)
                        } else { Text("已停用").font(.caption).foregroundStyle(RecallPalette.secondary) }
                    }.padding(12).background(RecallPalette.selected, in: RoundedRectangle(cornerRadius: 10))
                }
                if !resolution.changes.isEmpty {
                    DisclosureGroup("查看调整前后") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(resolution.changes.enumerated()), id: \.offset) { _, change in
                                VStack(alignment: .leading, spacing: 6) {
                                    if let old = entry.target.items.first(where: { $0.id == change.itemID }) {
                                        Text("原来：" + old.title + (old.detail.isEmpty ? "" : "\n" + old.detail)).foregroundStyle(RecallPalette.secondary)
                                    }
                                    Text(change.remove ? "调整：从这份回顾移除" : "调整：" + change.title + (change.detail.isEmpty ? "" : "\n" + change.detail))
                                }.font(.callout).textSelection(.enabled)
                            }
                        }.padding(.top, 10)
                    }.font(.caption)
                }
            }
            HStack(spacing: 14) {
                if [.failed, .waiting, .retrying].contains(entry.state) { Button("重试") { model.retryFeedback(entry.id) } }
                if entry.state != .withdrawn { Button(entry.state.pending ? "取消处理" : "撤销这次调整") { model.withdrawFeedback(entry.id) } }
                Spacer()
                Button("删除记录", role: .destructive) { model.deleteFeedback(entry.id) }
            }.font(.caption).buttonStyle(.borderless)
        }.padding(18).background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(RecallPalette.border))
    }
}
