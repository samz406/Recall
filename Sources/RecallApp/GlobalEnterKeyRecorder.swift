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
        case .inputMonitoringPermissionRequired: "需要允许输入监控与辅助功能"
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
/// the `enterKeyTrigger` rule. The event tap is listen-only and never consumes keystrokes.
@MainActor
final class GlobalEnterKeyRecorder {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onEnter: (() -> Void)?
    private var lastTriggerAt: Date?
    private let cooldown: TimeInterval = 2

    func update(isEnabled: Bool, onEnter: @escaping () -> Void) -> GlobalEnterKeyRecorderStatus {
        self.onEnter = onEnter
        guard isEnabled else {
            stop()
            return .disabled
        }
        guard hasRequiredPermissions() else {
            stop()
            return .inputMonitoringPermissionRequired
        }
        guard eventTap == nil else { return .monitoring }

        let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: keyDownMask,
            callback: globalEnterEventTapCallback,
            userInfo: userInfo
        ) else {
            stop()
            return .inputMonitoringPermissionRequired
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        runLoopSource = source
        return .monitoring
    }

    /// This is only called from the explicit “检查键盘权限” user action.
    func requestRequiredPermissions() {
        _ = CGRequestListenEventAccess()
        let promptOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOptions)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        onEnter = nil
        lastTriggerAt = nil
    }

    private func hasRequiredPermissions() -> Bool {
        CGPreflightListenEventAccess() && AXIsProcessTrusted()
    }

    private func handleEnterPress() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        guard lastTriggerAt.map({ Date.now.timeIntervalSince($0) >= cooldown }) ?? true else { return }
        lastTriggerAt = .now
        onEnter?()
    }
}

private let globalEnterEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let recorder = Unmanaged<GlobalEnterKeyRecorder>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            recorder.reenableEventTapIfNeeded()
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == 36 || keyCode == 76 else { return Unmanaged.passUnretained(event) }
    Task { @MainActor in
        recorder.handleEnterPressFromEventTap()
    }
    return Unmanaged.passUnretained(event)
}

private extension GlobalEnterKeyRecorder {
    func handleEnterPressFromEventTap() {
        handleEnterPress()
    }

    func reenableEventTapIfNeeded() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}
