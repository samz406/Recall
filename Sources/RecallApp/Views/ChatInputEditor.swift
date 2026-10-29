import AppKit
import SwiftUI

/// Native multiline editor: preserves selection and IME composition, Shift-Return inserts a newline.
struct RecallChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let onFocus: (Bool) -> Void
    let onSubmit: () -> Void
    let onTab: () -> Bool
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = NSTextView()
        editor.delegate = context.coordinator; editor.isRichText = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 16); editor.textColor = .labelColor; editor.insertionPointColor = NSColor(RecallPalette.accent)
        editor.textContainerInset = .zero; editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.setAccessibilityLabel("向 Recall 提问，回车发送，Shift 加回车换行")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        editor.setFrameSize(NSSize(width: max(1, scroll.contentSize.width), height: max(44, editor.frame.height)))
        context.coordinator.measure(editor)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RecallChatInput
        init(_ parent: RecallChatInput) { self.parent = parent }
        func textDidBeginEditing(_ notification: Notification) { parent.onFocus(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocus(false) }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; measure(editor)
        }
        func measure(_ editor: NSTextView) {
            guard let manager = editor.layoutManager, let container = editor.textContainer else { return }
            manager.ensureLayout(for: container)
            let proposed = min(180, max(44, ceil(manager.usedRect(for: container).height) + 3))
            guard abs(parent.height - proposed) > 1 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.height = proposed }
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) { return false }
                parent.onSubmit(); return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) { return parent.onTab() }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            return false
        }
    }
}
