import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RecallKit

struct FirstMomentView: View {
    @EnvironmentObject private var model: RecallAppModel
    @State private var sample = false
    @State private var step = 0
    @State private var source: CaptureRecord?
    private let records = DemoWorkspace.records()
    init(sampleMode: Bool = false) { _sample = State(initialValue: sampleMode) }
    private func t(_ zh: String, _ en: String) -> String { RecallLocalization.both(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(sample ? t("样例 · 不会写入你的记忆", "Sample · Separate from your memory") : "Recall").font(.title2.bold())
                Spacer(); Button(t("完成", "Done")) { model.finishOnboarding() }
            }
            if sample { sampleContent }
            else {
                Image(systemName: "sparkle").font(.system(size: 38)).foregroundStyle(RecallPalette.accent)
                Text(t("留下一刻，找回上下文，继续手头的事。", "Save a moment. Find the context. Pick up where you left off.")).font(.title.weight(.semibold))
                Text(t("不连续录屏，不录音。先用本地样例走一遍，或写下你自己的第一条记录。", "No continuous recording. No audio. Try a local sample or write your first real record.")).foregroundStyle(RecallPalette.secondary)
                HStack(spacing: 14) {
                    Button(t("用样例试试", "Try a sample")) { sample = true }.buttonStyle(.borderedProminent)
                    Button(t("写第一条记录", "Write my first record")) { model.finishOnboarding(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { model.showsTextEntry = true } }
                }
                Text(t("样例无需权限、API Key 或网络。真实 AI 回顾需连接你选择的模型。", "The sample needs no permissions, API Key or network. Real AI reviews use a model you connect.")).font(.caption).foregroundStyle(RecallPalette.secondary)
            }
            Spacer(minLength: 8)
        }.padding(32).frame(width: 720, height: 550).background(RecallPalette.background)
            .sheet(item: $source) { record in VStack(alignment: .leading, spacing: 16) { Text("Sample · " + (record.windowTitle ?? "Record")).font(.headline); Text(record.ocrText).textSelection(.enabled); Button(t("完成", "Done")) { source = nil } }.padding(28).frame(width: 560) }
    }
    private var sampleContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Sample", selection: $step) { Text("Record").tag(0); Text("Daily Review").tag(1); Text("Ask").tag(2) }.pickerStyle(.segmented)
            Label(t("合成数据与预置结果，不是实时模型输出。", "Synthetic records and saved sample results, not a live model response."), systemImage: "info.circle").font(.caption).foregroundStyle(RecallPalette.secondary)
            if step == 0 {
                ForEach(records) { record in Button { source = record } label: { VStack(alignment: .leading, spacing: 8) { Text(record.windowTitle ?? "Record").font(.headline); Text(record.ocrText).foregroundStyle(RecallPalette.secondary).multilineTextAlignment(.leading) }.recallSurface() }.buttonStyle(.plain) }
            } else {
                Text(step == 1 ? DemoWorkspace.review : DemoWorkspace.answer).font(.system(size: 17)).lineSpacing(6).recallSurface()
                Text(t("查看来源", "Open a source")).font(.headline)
                ForEach(records) { record in Button((record.sourceAppName ?? "") + " · " + (record.windowTitle ?? "")) { source = record } }
                if step == 1 { Label(t("有明确承诺时，你可以将它加入今天；样例不会创建真实待办。", "A clear commitment can be added to Today. This sample never creates a real action."), systemImage: "checklist").font(.caption) }
            }
            HStack { Button(t("重置样例", "Reset sample")) { step = 0 }; Spacer(); if step < 2 { Button(t("下一步", "Next")) { step += 1 }.buttonStyle(.borderedProminent) } }
        }
    }
}

struct TextEvidenceEntrySheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var title = ""
    @State private var imported = false
    @State private var source = "Plain text"
    @State private var author = ""
    @State private var hasDate = false
    @State private var occurredAt = Date.now
    @State private var meetingID: UUID?
    @State private var importError: String?
    private func t(_ zh: String, _ en: String) -> String { RecallLocalization.both(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(t("保存文字", "Save text evidence")).font(.title2.bold()); Spacer(); Button(t("取消", "Cancel")) { dismiss() } }
            Picker(t("文字来自", "Text origin"), selection: $imported) { Text(t("我自己写的", "Written by me")).tag(false); Text(t("纪要或外部资料", "Meeting notes or reference")).tag(true) }.pickerStyle(.segmented)
            TextField(t("标题（选填）", "Title (optional)"), text: $title).textFieldStyle(.roundedBorder)
            if imported { importFields }
            TextEditor(text: $text).font(.system(size: 15)).padding(8).background(RecallPalette.surface).clipShape(RoundedRectangle(cornerRadius: 10)).frame(minHeight: 180)
            Text(t("导入资料不等于本人承诺。保存后可查看、纠正或删除；不会自动发送给模型。", "Imported material is not your personal commitment. You can inspect, correct or delete it. Saving does not automatically authorize a model request.")).font(.caption).foregroundStyle(RecallPalette.secondary)
            if let importError { Text(importError).font(.caption).foregroundStyle(RecallPalette.warning) }
            HStack {
                Button(t("导入 .txt / .md", "Import .txt / .md")) { importFile() }
                Spacer()
                Button(t("保存到记忆", "Save to memory")) { model.saveTextEntry(text, title: title, imported: imported, source: source, author: author, occurredAt: hasDate ? occurredAt : nil, meetingID: meetingID) }
                    .buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 250_000)
            }
        }.padding(28).frame(width: 740, height: imported ? 700 : 520).background(RecallPalette.background)
    }
    private var importFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(t("来源", "Source"), selection: $source) { ForEach(["Plain text", "Granola", "Otter", "Teams", "Zoom", "Other"], id: \.self) { Text($0) } }
                TextField(t("原作者（选填）", "Original author (optional)"), text: $author).textFieldStyle(.roundedBorder)
            }
            Picker(t("关联会议", "Related meeting"), selection: $meetingID) {
                Text(t("不关联", "None")).tag(Optional<UUID>.none)
                ForEach(model.state.workflow.meetings) { Text($0.title).tag(Optional($0.id)) }
            }
            Toggle(t("指定原始时间", "Set original date"), isOn: $hasDate)
            if hasDate { DatePicker(t("原始时间", "Original date"), selection: $occurredAt) }
        }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 250_000 else { throw WorkflowError.invalid }
            text = try String(contentsOf: url, encoding: .utf8); title = url.deletingPathExtension().lastPathComponent; imported = true
        } catch { importError = t("仅支持 250 KB 以内的 UTF-8 文本。", "Choose a UTF-8 text file smaller than 250 KB.") }
    }
}
