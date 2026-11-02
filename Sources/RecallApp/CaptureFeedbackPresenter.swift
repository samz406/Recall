import AppKit
import SwiftUI
import RecallKit

/// Shown after capture completes, so the feedback cannot cover the saved screenshot.
/// Nonactivating: the user's working app keeps keyboard focus. No notification permission.
@MainActor final class CaptureFeedbackPresenter {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    func show(_ message: String, target: CaptureTarget?, undo: (() -> Void)? = nil) {
        dismissal?.cancel(); panel?.orderOut(nil)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 98),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.level = .floating; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: CaptureFeedbackView(message: message, undo: undo.map { action in
            { [weak self] in self?.panel?.orderOut(nil); action() }
        }).recallColors())
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target?.displayID } ?? NSScreen.main
        if let frame = screen?.visibleFrame { window.setFrameOrigin(NSPoint(x: frame.maxX - 410, y: frame.maxY - 118)) }
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
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: undo == nil ? "info.circle" : "checkmark.circle.fill").foregroundStyle(RecallPalette.accent)
            Text(message).font(.callout).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            if let undo { Button(RecallLocalization.text("撤销"), action: undo).buttonStyle(.plain).foregroundStyle(RecallPalette.accent) }
        }.padding(18).frame(width: 390, height: 98).background(RecallPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(RecallPalette.border))
    }
}
