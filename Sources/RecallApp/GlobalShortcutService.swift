import AppKit
import Carbon
import RecallKit

struct GlobalShortcutBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled = true
    static let record = GlobalShortcutBinding(keyCode: 15, modifiers: UInt32(controlKey | optionKey | cmdKey))
    static let ask = GlobalShortcutBinding(keyCode: 0, modifiers: UInt32(controlKey | optionKey | cmdKey))
    var label: String {
        let keys: [UInt32: String] = [15: "R", 0: "A", 36: "↩", 49: "Space"]
        return (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + (keys[keyCode] ?? "Key \(keyCode)")
    }
}
@MainActor final class GlobalShortcutService {
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var record: (() -> Void)?
    private var ask: (() -> Void)?
    private var lastTrigger = Date.distantPast
    func configure(record binding: GlobalShortcutBinding, ask askBinding: GlobalShortcutBinding,
                   onRecord: @escaping () -> Void, onAsk: @escaping () -> Void) -> Bool {
        stop(); record = onRecord; ask = onAsk
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), recallHotKeyCallback, 1, &spec, context, &handler) == noErr else { return false }
        for (id, key) in [(UInt32(1), binding), (UInt32(2), askBinding)] where key.enabled {
            guard key.modifiers & UInt32(cmdKey | controlKey) != 0 else { stop(); return false }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: 0x52434C4C, id: id), GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { stop(); return false }; registrations.append(ref)
        }
        return true
    }
    func trigger(_ id: UInt32) {
        guard Date.now.timeIntervalSince(lastTrigger) > 0.5 else { return }; lastTrigger = .now
        if id == 1 { record?() } else if id == 2 { ask?() }
    }
    func stop() {
        registrations.forEach { UnregisterEventHotKey($0) }; registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
        record = nil; ask = nil
    }
}
private func recallHotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var key = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
    let service = Unmanaged<GlobalShortcutService>.fromOpaque(context).takeUnretainedValue()
    let id = key.id
    Task { @MainActor [weak service] in service?.trigger(id) }
    return noErr
}
