import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Carbon

public struct CaptureTarget: Sendable, Equatable {
    public var processID: Int32
    public var bundleIdentifier: String
    public var appName: String
    public var windowID: CGWindowID?
    public var displayID: CGDirectDisplayID?
    public init(processID: Int32, bundleIdentifier: String, appName: String, windowID: CGWindowID? = nil, displayID: CGDirectDisplayID? = nil) {
        self.processID = processID; self.bundleIdentifier = bundleIdentifier; self.appName = appName; self.windowID = windowID; self.displayID = displayID
    }
}
@MainActor public enum CaptureTargetResolver {
    public static func current() -> CaptureTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // CGWindowList is front-to-back. Never fall back to a different process.
        let window = windows.first {
            ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        var rect = CGRect.zero
        if let data = window?[kCGWindowBounds as String] as? [String: Any] { rect = CGRect(dictionaryRepresentation: data as CFDictionary) ?? .zero }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let display = rect.width > 0 && rect.height > 0 ? ids.prefix(Int(count)).max { a, b in
            func area(_ id: CGDirectDisplayID) -> CGFloat { let r = CGDisplayBounds(id).intersection(rect); return r.isNull ? 0 : r.width * r.height }
            return area(a) < area(b)
        } : nil
        return CaptureTarget(processID: app.processIdentifier, bundleIdentifier: bundle, appName: app.localizedName ?? bundle,
            windowID: (window?[kCGWindowNumber as String] as? NSNumber)?.uint32Value, displayID: display)
    }
}

/// Reads the front window's title, page address and secure-input state for the privacy decision.
@MainActor public protocol CaptureContextReading {
    func context(for target: CaptureTarget?, settings: PrivacySettings) -> CaptureContext
}

@MainActor public struct LiveCaptureContextReader: CaptureContextReading {
    public init() {}
    public func context(for target: CaptureTarget?, settings: PrivacySettings) -> CaptureContext {
        let bundle = target?.bundleIdentifier
        let title = target.flatMap { Self.windowTitle(windowID: $0.windowID) }
        // The address is read only when a setting needs it, and only from a browser.
        let needsURL = settings.recordPageAddress || !settings.excludedDomains.isEmpty
        let url = needsURL && bundle.map(PrivacyEngine.browserBundleIdentifiers.contains) == true
            ? target.flatMap { BrowserAddressReader.address(processID: $0.processID) } : nil
        return CaptureContext(bundleIdentifier: bundle, windowTitle: title, pageURL: url, secureInputActive: IsSecureEventInputEnabled())
    }
    public static func windowTitle(windowID: CGWindowID?) -> String? {
        guard let windowID, let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first else { return nil }
        return info[kCGWindowName as String] as? String
    }
}

/// Uses Accessibility to find the focused web area's URL. Never prompts: without trust it returns nil.
public enum BrowserAddressReader {
    @MainActor public static func address(processID: Int32) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var queue: [AXUIElement] = [window as! AXUIElement], visited = 0
        while !queue.isEmpty, visited < 400 {
            let element = queue.removeFirst(); visited += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWebArea" {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success {
                    if let url = value as? URL { return url.absoluteString }
                    if let text = value as? String { return text }
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] { queue.append(contentsOf: list) }
        }
        return nil
    }
}
