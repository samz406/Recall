import AppKit
import SwiftUI
import RecallKit

/// Shown after capture completes, so the feedback cannot cover the saved screenshot.
/// Nonactivating: the user's working app keeps keyboard focus. No notification permission.
@MainActor final class CaptureFeedbackPresenter {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    func dismiss() { dismissal?.cancel(); panel?.orderOut(nil) }
    func show(_ message: String, target: CaptureTarget?, undo: (() -> Void)? = nil, addNote: ((String) -> Void)? = nil) {
        dismiss()
        let height: CGFloat = addNote == nil ? 98 : 136
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.becomesKeyOnlyIfNeeded = true; window.isOpaque = false; window.backgroundColor = .clear
        window.level = .floating; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: CaptureFeedbackView(message: message, undo: undo.map { action in
            { [weak self] in self?.panel?.orderOut(nil); action() }
        }, addNote: addNote.map { save in
            { [weak self] note in self?.panel?.orderOut(nil); save(note) }
        }, holdOpen: { [weak self] in self?.dismissal?.cancel() }).recallColors())
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target?.displayID } ?? NSScreen.main
        if let frame = screen?.visibleFrame { window.setFrameOrigin(NSPoint(x: frame.maxX - 410, y: frame.maxY - height - 20)) }
        panel = window; window.orderFrontRegardless()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            self?.panel?.orderOut(nil)
        }
    }
}
private struct CaptureFeedbackView: View {
    let message: String
    let undo: (() -> Void)?
    var addNote: ((String) -> Void)? = nil
    var holdOpen: () -> Void = {}
    @State private var writing = false
    @State private var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: undo == nil ? "info.circle" : "checkmark.circle.fill").foregroundStyle(RecallPalette.accent)
                Text(message).font(.callout).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                if let undo { Button(RecallLocalization.text("撤销"), action: undo).buttonStyle(.plain).foregroundStyle(RecallPalette.accent) }
            }
            if let addNote {
                if writing {
                    // The panel never takes focus on its own; clicking "Add note" is the user's choice to type here.
                    TextField(RecallLocalization.both("为什么存这条？回车保存", "Why keep this? Press Return"), text: $note)
                        .textFieldStyle(.roundedBorder).onSubmit { addNote(note) }
                } else {
                    Button(RecallLocalization.both("加一句备注", "Add a note")) {
                        holdOpen(); writing = true; NSApp.activate()
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(RecallPalette.accent)
                }
            }
        }.padding(18).frame(width: 390).background(RecallPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(RecallPalette.border))
    }
}
