import Foundation
import AppKit
import CoreGraphics

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
        let display = ids.prefix(Int(count)).max { a, b in
            func area(_ id: CGDirectDisplayID) -> CGFloat { let r = CGDisplayBounds(id).intersection(rect); return r.isNull ? 0 : r.width * r.height }
            return area(a) < area(b)
        }
        return CaptureTarget(processID: app.processIdentifier, bundleIdentifier: bundle, appName: app.localizedName ?? bundle,
            windowID: (window?[kCGWindowNumber as String] as? NSNumber)?.uint32Value, displayID: display)
    }
}
