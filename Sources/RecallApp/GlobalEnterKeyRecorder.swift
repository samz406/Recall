import AppKit
import Foundation

/// Observes Return/Enter presses outside Recall after the user explicitly enables
/// the `enterKeyTrigger` event rule. The monitor never consumes keystrokes.
@MainActor
final class GlobalEnterKeyRecorder {
    private var monitor: Any?
    private var onEnter: (() -> Void)?
    private var lastTriggerAt: Date?
    private let cooldown: TimeInterval = 2

    func update(isEnabled: Bool, onEnter: @escaping () -> Void) {
        self.onEnter = onEnter
        guard isEnabled else {
            stop()
            return
        }
        guard monitor == nil else { return }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 36 || event.keyCode == 76 else { return }
            Task { @MainActor [weak self] in
                self?.handleEnterPress()
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onEnter = nil
        lastTriggerAt = nil
    }

    private func handleEnterPress() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        guard lastTriggerAt.map({ Date.now.timeIntervalSince($0) >= cooldown }) ?? true else { return }
        lastTriggerAt = .now
        onEnter?()
    }
}
