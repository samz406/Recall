import AppKit
import ApplicationServices
import Foundation
import RecallKit

/// Ways to save something other than a screenshot. Each one is an explicit user action, goes
/// through the same privacy and suppression rules, and can be undone from the feedback panel.
extension RecallAppModel {
    /// Reads the selected text in the front app through Accessibility. Never simulates ⌘C and never
    /// reads the clipboard; without Accessibility trust it explains how to enable it instead.
    func saveFrontSelection() {
        guard !isRecording else { return }
        let target = CaptureTargetResolver.current()
        guard let target, target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            noticeMessage = RecallLocalization.both("请先切换到要保存文字的应用。", "Switch to the app with the selected text first."); return
        }
        guard AXIsProcessTrusted() else {
            captureFeedback.show(RecallLocalization.both("保存选中文字需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能。也可以用“服务”菜单或剪贴板保存。",
                "Saving a selection needs Accessibility access (System Settings → Privacy & Security → Accessibility). The Services menu or clipboard also works."), target: target)
            return
        }
        guard let text = Self.selectedText(processID: target.processID), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            captureFeedback.show(RecallLocalization.both("没有读到选中的文字。部分应用不提供选中内容，可改用“服务”菜单或复制后从菜单栏保存剪贴板。",
                "No selected text was found. Some apps do not expose it; use the Services menu or save the clipboard instead."), target: target)
            return
        }
        saveText(text, origin: .selectedText, appName: target.appName, bundleIdentifier: target.bundleIdentifier, target: target)
    }

    /// Saves the current clipboard text. Only on an explicit click; Recall never watches the clipboard.
    func saveClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            noticeMessage = RecallLocalization.both("剪贴板里没有文字。", "The clipboard has no text."); return
        }
        let target = lastExternalTarget
        saveText(text, origin: .selectedText, appName: RecallLocalization.both("剪贴板", "Clipboard"), bundleIdentifier: "im.recall.clipboard",
                 windowTitle: target.map { RecallLocalization.both("复制自 ", "Copied from ") + $0.appName })
    }

    /// Text handed over by the macOS Services menu ("Save to Recall").
    func saveServiceText(_ text: String) {
        let target = lastExternalTarget
        saveText(text, origin: .selectedText, appName: target?.appName ?? RecallLocalization.both("服务菜单", "Services"),
                 bundleIdentifier: target?.bundleIdentifier ?? "im.recall.service", target: target)
    }

    /// Files dropped on the window. Text is extracted on this Mac; the file itself is not copied.
    func importFiles(_ urls: [URL]) {
        guard !isRecording, !urls.isEmpty else { return }
        isRecording = true
        Task {
            defer { isRecording = false }
            var saved = 0, failures: [String] = []
            for url in urls.prefix(20) {
                do {
                    let text = try await FileTextImporter().text(from: url)
                    _ = try await pipeline.recordText(text, origin: .importedText, sourceAppName: RecallLocalization.both("导入文件", "Imported file"),
                        sourceBundleIdentifier: "im.recall.file", windowTitle: url.lastPathComponent)
                    saved += 1
                } catch { failures.append(url.lastPathComponent + "：" + error.localizedDescription) }
            }
            await refresh()
            recordDiagnostic(failures.isEmpty ? .info : .warning, source: "Import", message: "导入文件完成",
                             metadata: ["saved": "\(saved)", "failed": "\(failures.count)"])
            noticeMessage = failures.isEmpty
                ? RecallLocalization.both("已导入 \(saved) 个文件的文字。", "Imported text from \(saved) file(s).")
                : RecallLocalization.both("已导入 \(saved) 个；未导入：", "Imported \(saved); skipped: ") + failures.prefix(3).joined(separator: "；")
        }
    }

    private func saveText(_ text: String, origin: CaptureTextOrigin, appName: String?, bundleIdentifier: String?, windowTitle: String? = nil, target: CaptureTarget? = nil) {
        guard !isRecording else { return }
        guard !showsOnboarding else { noticeMessage = RecallLocalization.both("请先退出样例，再保存真实记录。", "Leave the sample before saving a real record."); return }
        isRecording = true
        Task {
            defer { isRecording = false }
            do {
                let record = try await pipeline.recordText(text, origin: origin, sourceAppName: appName, sourceBundleIdentifier: bundleIdentifier,
                                                           windowTitle: windowTitle, target: target)
                await refresh()
                recordDiagnostic(.info, source: "TextCapture", message: "文字已保存", metadata: ["characters": "\(record.ocrText.count)"])
                showSavedFeedback(record, target: target)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? RecallLocalization.both("未能保存文字。", "Could not save the text.")
                recordDiagnostic(.warning, source: "TextCapture", message: "文字未保存", metadata: ["error": recallSafeErrorCode(error)])
                captureFeedback.show(message, target: target)
            }
        }
    }

    /// Feedback after any save: what was kept, how much text, plus Undo and Add note.
    func showSavedFeedback(_ record: CaptureRecord, target: CaptureTarget?) {
        captureFeedback.show(Self.savedMessage(for: record), target: target,
            undo: { [weak self] in self?.deleteCapture(record) },
            addNote: { [weak self] note in self?.setNote(record.id, note: note) })
    }

    static func savedMessage(for record: CaptureRecord) -> String {
        let count = record.ocrText.count
        if count == 0 {
            return record.imageRelativePath == nil
                ? RecallLocalization.both("已保存，但没有识别到文字。", "Saved, but no text was recognized.")
                : RecallLocalization.both("已保存截图，但没有识别到文字。可在详情中查看原图。", "Screenshot saved, but no text was recognized. Open details to see it.")
        }
        let kind = record.imageRelativePath == nil ? RecallLocalization.both("已保存文字", "Text saved") : RecallLocalization.both("已保存截图", "Screenshot saved")
        return kind + RecallLocalization.both("，识别 \(count) 字", " · \(count) characters") + (record.isRedacted ? RecallLocalization.both("（已隐藏敏感内容）", " (sensitive text hidden)") : "")
    }

    func setNote(_ id: UUID, note: String?) {
        Task {
            do { try await store.setCaptureNote(id, note: note); await refresh() }
            catch { recordError(error, source: "Note", message: "保存备注失败") }
        }
    }

    /// "How did I do this last time": past records related to the front window's title. Read-only.
    func showLastTime() {
        let target = CaptureTargetResolver.current()
        let external = target?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastExternalTarget : target
        let title = external.flatMap { LiveCaptureContextReader.windowTitle(windowID: $0.windowID) } ?? ""
        guard let external, !title.isEmpty else {
            noticeMessage = RecallLocalization.both("没有读到当前窗口标题，请切换到要查的窗口后再按快捷键。", "No window title found. Switch to the window you want to look up and try again.")
            openMainWindow?(); return
        }
        lastTimeQuery = LastTimeQuery(title: title, appName: external.appName,
            records: LocalBriefing.related(title: title, bundleIdentifier: external.bundleIdentifier, in: state))
        openMainWindow?()
    }

    private static func selectedText(processID: Int32) -> String? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        // A secure field never exposes its value, but refuse anything that reports the secure role.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        if (role as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

struct LastTimeQuery: Identifiable {
    let id = UUID()
    let title: String
    let appName: String
    let records: [CaptureRecord]
}

/// Receives "Save to Recall" from the macOS Services menu.
@MainActor final class RecallServiceProvider: NSObject {
    weak var model: RecallAppModel?
    @objc func saveToRecall(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = RecallLocalization.both("没有可保存的文字。", "No text to save.") as NSString; return
        }
        guard let model else { error.pointee = RecallLocalization.both("Recall 仍在启动。", "Recall is still starting.") as NSString; return }
        model.saveServiceText(text)
    }
}
