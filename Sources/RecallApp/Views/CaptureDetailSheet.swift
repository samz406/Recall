import AppKit
import RecallKit
import SwiftUI

struct CaptureDetailSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let capture: CaptureRecord
    var embedded = false
    var close: (() -> Void)? = nil
    @State private var screenshot: NSImage?
    @State private var didCopy = false

    private var presentation: CapturePresentation { CapturePresentation(capture: capture) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text(capture.createdAt.formatted(.dateTime.locale(RecallLocalization.locale).year().month().day().hour().minute()))
                        .font(.subheadline)
                        .foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button(RecallLocalization.text("关闭")) { if embedded { close?() } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GroupBox(RecallLocalization.text("来源")) {
                        VStack(alignment: .leading, spacing: 8) {
                            metadata("应用", capture.sourceAppName ?? "未知应用")
                            if let window = capture.windowTitle, !window.isEmpty {
                                metadata("窗口", window)
                            }
                            metadata("记录方式", capture.eventTemplate.title)
                            if let imported = capture.importMetadata {
                                metadata(RecallLocalization.both("文字来源", "Text origin"), RecallLocalization.both("导入资料（非本人承诺）", "Imported reference, not a personal commitment"))
                                if let author = imported.author { metadata(RecallLocalization.both("原作者", "Original author"), author) }
                                if let original = imported.occurredAt {
                                    metadata(RecallLocalization.both("原始时间", "Original date"), original.formatted(.dateTime.locale(RecallLocalization.locale).year().month().day().hour().minute()))
                                }
                            }
                            if capture.isRedacted {
                                Label(RecallLocalization.text("识别文本已脱敏"), systemImage: "lock.fill")
                                    .font(.caption).foregroundStyle(RecallPalette.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(RecallLocalization.both("长期保留这条文字记录", "Keep this text record"), isOn: Binding(
                            get: { model.state.captures.first { $0.id == capture.id }?.keepTextIndefinitely == true },
                            set: { model.setKeepText(capture.id, enabled: $0) }))
                        Text(RecallLocalization.both("不受文字保留期限限制；截图仍按原期限清理。手动删除仍然有效。", "Exempt from text expiry. Screenshots still follow their retention period, and you can delete this record anytime.")).font(.caption).foregroundStyle(RecallPalette.secondary)
                    }
                    CaptureUnderstandingDetailView(captureID: capture.id).environmentObject(model)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(RecallLocalization.text("内容摘要")).font(.headline)
                        Text(presentation.summary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(RecallLocalization.text("完整识别文本")).font(.headline)
                            Text(RecallLocalization.both("\(capture.ocrText.count) 字符", "\(capture.ocrText.count) characters"))
                                .font(.caption).foregroundStyle(RecallPalette.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                didCopy = NSPasteboard.general.setString(capture.ocrText, forType: .string)
                            } label: {
                                Label(RecallLocalization.text(didCopy ? "已复制" : "复制全文"), systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            }
                            .disabled(capture.ocrText.isEmpty)
                        }
                        Text(capture.textOrigin == .screenOCR ? RecallLocalization.text("以下为当时保存的识别文本，仅覆盖截图中的可见内容，可能包含识别误差。") : RecallLocalization.both("以下为保存时的文字；导入资料中的发言不自动归属于你。", "Text as saved. Statements in imported material are not automatically attributed to you."))
                            .font(.caption).foregroundStyle(RecallPalette.secondary)
                        Text(capture.ocrText.isEmpty ? RecallLocalization.text("这条记录没有识别出文本。") : capture.ocrText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .background(RecallPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(RecallLocalization.text("原始截图")).font(.headline)
                        if let screenshot {
                            Image(nsImage: screenshot)
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel(RecallLocalization.text("记录时的窗口截图"))
                        } else {
                            Text(RecallLocalization.text(capture.imageRelativePath == nil
                                ? "这条记录未保留截图。"
                                : "截图文件已清理或无法读取，识别文本仍可查看。"))
                                .foregroundStyle(RecallPalette.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: embedded ? 400 : 620, idealWidth: embedded ? 500 : 760, minHeight: 480, idealHeight: 680)
        .task(id: capture.id) {
            if let path = capture.imageRelativePath {
                screenshot = NSImage(contentsOf: model.storage.screenshotURL(relativePath: path))
            } else {
                screenshot = nil
            }
        }
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(RecallLocalization.text(label)).foregroundStyle(RecallPalette.secondary).frame(width: RecallLocalization.isEnglish ? 100 : 64, alignment: .leading)
            Text(RecallLocalization.text(value)).textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
