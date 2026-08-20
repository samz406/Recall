import AppKit
import ApplicationServices
import Foundation

enum GlobalEnterKeyRecorderStatus: Equatable {
    case disabled
    case inputMonitoringPermissionRequired
    case monitoring

    var title: String {
        switch self {
        case .disabled: "未启用"
        case .inputMonitoringPermissionRequired: "需要允许键盘输入监控"
        case .monitoring: "正在监听其他应用中的 Enter 键"
        }
    }

    var symbolName: String {
        switch self {
        case .disabled: "keyboard"
        case .inputMonitoringPermissionRequired: "keyboard.badge.ellipsis"
        case .monitoring: "keyboard.badge.eye"
        }
    }
}

/// Observes Return/Enter presses outside Recall after the user explicitly enables
/// the `enterKeyTrigger` event rule. The monitor never consumes keystrokes.
@MainActor
final class GlobalEnterKeyRecorder {
    private var monitor: Any?
    private var onEnter: (() -> Void)?
    private var lastTriggerAt: Date?
    private let cooldown: TimeInterval = 2

    func update(isEnabled: Bool, onEnter: @escaping () -> Void) -> GlobalEnterKeyRecorderStatus {
        self.onEnter = onEnter
        guard isEnabled else {
            stop()
            return .disabled
        }
        guard CGPreflightListenEventAccess() else {
            stop()
            return .inputMonitoringPermissionRequired
        }
        guard monitor == nil else { return .monitoring }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 36 || event.keyCode == 76 else { return }
            Task { @MainActor [weak self] in
                self?.handleEnterPress()
            }
        }
        return monitor == nil ? .inputMonitoringPermissionRequired : .monitoring
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
