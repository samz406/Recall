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
        let editor = RecallInputTextView()
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
                if ((textView as? RecallInputTextView)?.lastModifiers ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift) { return false }
                parent.onSubmit(); return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) { return parent.onTab() }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            return false
        }
    }
}

@MainActor
private final class RecallInputTextView: NSTextView {
    var lastModifiers: NSEvent.ModifierFlags = []
    override func keyDown(with event: NSEvent) {
        lastModifiers = event.modifierFlags
        super.keyDown(with: event)
    }
}

extension RecallChatInput {
    @MainActor static func verifyKeyboardBehavior() async throws {
        final class Probe { var text = "首行"; var height: CGFloat = 44; var sends = 0 }
        let probe = Probe()
        let input = RecallChatInput(text: Binding(get: { probe.text }, set: { probe.text = $0 }), height: Binding(get: { probe.height }, set: { probe.height = $0 }), onFocus: { _ in }, onSubmit: { probe.sends += 1 }, onTab: { false }, onEscape: {})
        let coordinator = input.makeCoordinator()
        let editor = RecallInputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 44))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        defer { window.orderOut(nil) }
        editor.isRichText = false; editor.string = probe.text; editor.delegate = coordinator
        editor.setSelectedRange(NSRange(location: (probe.text as NSString).length, length: 0))
        func enter(shift: Bool) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            editor.keyDown(with: event)
        }
        enter(shift: true)
        guard probe.text.contains("\n"), probe.sends == 0 else { throw KeyboardFailure.contract }
        enter(shift: false)
        guard probe.sends == 1 else { throw KeyboardFailure.contract }
        editor.setMarkedText("中文组词", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        guard !coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), probe.sends == 1 else { throw KeyboardFailure.contract }
        editor.unmarkText()
        editor.string = String(repeating: "这是一段用于验证自动增高的合成文字。", count: 20)
        editor.isVerticallyResizable = true
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        coordinator.measure(editor)
        try await Task.sleep(for: .milliseconds(20))
        guard probe.height > 44 && probe.height <= 180 else { throw KeyboardFailure.contract }
        print("PASS: native chat input Shift-Return inserts newline, Return sends, IME composition does not send, multiline content grows within its limit")
    }
    private enum KeyboardFailure: Error { case contract }
}
