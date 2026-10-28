import RecallKit
import SwiftUI

struct CaptureUnderstandingSettingsView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var showQueue = false
    private var waiting: Int { model.state.understandingJobs.filter { [.queued, .retrying, .processing].contains($0.state) }.count }
    private var failed: Int { model.state.understandingJobs.filter { $0.state == .failed }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("采集后自动理解新记录", isOn: Binding(get: { model.state.understandingSettings.enabled }, set: { value in model.setCaptureUnderstandingEnabled(value) }))
            Text("先保存识别文字，再用模型核对事情、角色和状态。回顾会复用这些结果；未完成的历史记录会在生成回顾时补齐。仅发送脱敏文本，可暂停自动处理。")
                .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
            if model.state.understandingSettings.enabled && (!model.state.privacy.cloudUseEnabled || model.state.llmConfiguration.apiKey.isEmpty) {
                Label("连接模型并允许使用脱敏文本后开始整理", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            HStack(spacing: 12) {
                Button("整理近 30 天记录") { model.queueCaptureUnderstanding() }
                    .disabled(!model.state.understandingSettings.enabled)
                Button("查看进度") { showQueue = true }
                Spacer()
                Text(waiting > 0 ? "\(waiting) 条待整理" : "暂无等待中的记录")
                    .font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            if failed > 0 {
                HStack {
                    Text("\(failed) 条未通过核对或连接失败，原文仍可使用。")
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                    Button("重试") { model.queueCaptureUnderstanding(retryFailed: true) }
                        .disabled(!model.state.understandingSettings.enabled)
                }
            }
        }.sheet(isPresented: $showQueue) { CaptureUnderstandingQueueView().environmentObject(model) }
    }
}

private struct CaptureUnderstandingQueueView: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var limit = 40
    var body: some View {
        let jobs = model.state.understandingJobs.sorted { $0.updatedAt > $1.updatedAt }
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("记录整理").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() } }
            Text(model.state.understandingSettings.enabled ? "关闭应用后任务会暂停，下次启动继续。" : "已暂停，已保存的整理结果仍可使用。")
                .foregroundStyle(RecallPalette.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if jobs.isEmpty { Text("启用后，新记录会在后台逐段整理。").foregroundStyle(RecallPalette.secondary) }
                    ForEach(Array(jobs.prefix(limit))) { job in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                if let record = model.state.captures.first(where: { $0.id == job.captureID }) {
                                    Text(CapturePresentation(capture: record).title).lineLimit(2)
                                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                                }
                                Text(job.label).font(.caption).foregroundStyle(RecallPalette.secondary)
                                if let reason = job.lastFailureReason {
                                    Text(reason).font(.caption).foregroundStyle(RecallPalette.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            if job.state == .failed {
                                Button("重试") { model.queueCaptureUnderstanding(captureID: job.captureID) }
                                    .disabled(!model.state.understandingSettings.enabled)
                            }
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    if jobs.count > limit { Button("再显示 40 条") { limit += 40 } }
                }
            }
        }.padding(26).frame(width: 650, height: 540).tint(RecallPalette.accent)
    }
}

private extension CaptureUnderstandingJob {
    var label: String {
        switch state {
        case .queued: nextPage > 0 ? "已整理 \(nextPage) / \(pageCount) 段，等待继续" : "等待整理"
        case .processing: "正在核对第 \(nextPage + 1) / \(pageCount) 段"
        case .retrying: "稍后自动重试（已尝试 \(attempts) 次）"
        case .failed: "已停止自动重试，原文保留"
        case .completed: "整理完成"
        case .discarded: "整理结果已删除，可手动重新整理"
        }
    }
}

struct CaptureUnderstandingDetailView: View {
    @EnvironmentObject private var model: RecallAppModel
    let captureID: UUID
    @State private var editing = false
    private var source: CaptureRecord? { model.state.captures.first { $0.id == captureID } }
    var body: some View {
        if let source, source.manualMatter == nil, source.memoryDirective == nil, source.isMemoryEvidenceArchive != true {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("理解这条记录").font(.headline)
                    Spacer()
                    Menu {
                        Button("重新整理") { model.queueCaptureUnderstanding(captureID: captureID) }
                            .disabled(!model.state.understandingSettings.enabled)
                        Button("更正识别文字") { editing = true }
                        if source.understanding != nil {
                            Button("删除整理结果", role: .destructive) { model.removeCaptureUnderstanding(captureID) }
                        }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("管理记录理解") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if let result = source.understanding {
                    if result.facts.isEmpty {
                        Text("暂未发现有充分依据的事实或行动。原文已保留，可以更正文字后重新整理。")
                            .foregroundStyle(RecallPalette.secondary)
                    }
                    ForEach(result.facts) { fact in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(fact.subject).fontWeight(.semibold)
                            if fact.detail != fact.subject { Text(fact.detail).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                            Text(fact.kind == .reference ? "保存或引用的内容" : fact.speaker == .user ? "本人表达" : fact.speaker == .other ? "对方表达" : "说话人尚不明确")
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                            if let condition = fact.condition { Text("前提：\(condition)").font(.callout).foregroundStyle(RecallPalette.secondary) }
                            if let time = fact.messageTime { Text("原文消息时间：\(time.text)").font(.caption) }
                            if let time = fact.eventTime { Text("原文发生时间：\(time.text)").font(.caption) }
                            if let time = fact.deadline { Text("原文截止时间：\(time.text)").font(.caption) }
                            DisclosureGroup("原文片段") {
                                Text(fact.evidence.map(\.quote).joined(separator: "\n"))
                                    .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.caption).foregroundStyle(RecallPalette.secondary)
                        }.padding(.vertical, 5)
                    }
                    Text("整理于 \(result.createdAt.formatted(date: .abbreviated, time: .shortened))" + (result.uncertainBlockCount > 0 ? " · 部分文字暂无法判断" : ""))
                        .font(.caption).foregroundStyle(RecallPalette.secondary)
                } else if let job = model.state.understandingJobs.first(where: { $0.captureID == captureID }) {
                    Text(job.label).foregroundStyle(RecallPalette.secondary)
                } else {
                    Text("尚未整理，可在设置中开启后台理解。识别文字仍可搜索和回顾。")
                        .foregroundStyle(RecallPalette.secondary)
                }
            }.padding(16).background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 12))
                .sheet(isPresented: $editing) { CaptureTextCorrectionView(source: source).environmentObject(model) }
        }
    }
}

private struct CaptureTextCorrectionView: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let source: CaptureRecord
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更正识别文字").font(.title2.weight(.semibold))
            Text("修正错字或说话人标记。原始识别文字仍保留，后续理解使用更正后的版本。相关回顾和记忆将重新核对。")
                .font(.callout).foregroundStyle(RecallPalette.secondary)
            TextEditor(text: $text).font(.body).frame(minHeight: 300)
            if let error { Text(error).foregroundStyle(RecallPalette.danger) }
            HStack {
                if source.correctedText != nil { Button("恢复原始文字") { save(nil) }.disabled(saving) }
                Spacer(); Button("取消") { dismiss() }.disabled(saving)
                Button("保存更正") { save(text) }.buttonStyle(.borderedProminent)
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 700, height: 520).tint(RecallPalette.accent)
            .onAppear { text = source.correctedText ?? source.ocrText }
    }
    private func save(_ value: String?) {
        saving = true
        Task {
            do { try await model.store.correctCaptureText(source.id, text: value); await model.refresh(); dismiss() }
            catch { self.error = error.localizedDescription; saving = false }
        }
    }
}
