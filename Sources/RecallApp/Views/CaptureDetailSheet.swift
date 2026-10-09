import AppKit
import RecallKit
import SwiftUI

struct CaptureDetailSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    let capture: CaptureRecord
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
                    Text(capture.createdAt.formatted(date: .complete, time: .standard))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GroupBox("来源") {
                        VStack(alignment: .leading, spacing: 8) {
                            metadata("应用", capture.sourceAppName ?? "未知应用")
                            if let window = capture.windowTitle, !window.isEmpty {
                                metadata("窗口", window)
                            }
                            metadata("记录方式", capture.eventTemplate.title)
                            if capture.isRedacted {
                                Label("识别文本已脱敏", systemImage: "lock.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("内容摘要").font(.headline)
                        Text(presentation.summary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("完整识别文本").font(.headline)
                            Text("\(capture.ocrText.count) 字符")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                didCopy = NSPasteboard.general.setString(capture.ocrText, forType: .string)
                            } label: {
                                Label(didCopy ? "已复制" : "复制全文", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            }
                            .disabled(capture.ocrText.isEmpty)
                        }
                        Text("以下为当时保存的识别文本，仅覆盖截图中的可见内容，可能包含识别误差。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(capture.ocrText.isEmpty ? "这条记录没有识别出文本。" : capture.ocrText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("原始截图").font(.headline)
                        if let screenshot {
                            Image(nsImage: screenshot)
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("记录时的窗口截图")
                        } else {
                            Text(capture.imageRelativePath == nil
                                ? "这条记录未保留截图。"
                                : "截图文件已清理或无法读取，识别文本仍可查看。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 480, idealHeight: 680)
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
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
