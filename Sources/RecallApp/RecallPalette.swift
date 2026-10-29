import AppKit
import SwiftUI

/// Warm paper × forest green. Light values follow the supplied palette exactly;
/// dark counterparts preserve the same roles without overriding system appearance.
@MainActor
enum RecallPalette {
    static let accent = adaptive("accent", light: 0x426B55, dark: 0x96B99F)
    static let background = adaptive("background", light: 0xF8F7F3, dark: 0x1E2420)
    static let sidebar = adaptive("sidebar", light: 0xF0F1EB, dark: 0x181F1A)
    static let text = adaptive("text", light: 0x292F2B, dark: 0xE4E9E1)
    static let selected = adaptive("selected", light: 0xE5EEE6, dark: 0x2C4032)
    static let surface = adaptive("surface", light: 0xFFFFFF, dark: 0x252D27)
    static let secondary = adaptive("secondary", light: 0x626D64, dark: 0xA4B0A6)
    static let border = adaptive("border", light: 0xDDE1D8, dark: 0x414D43)
    static let onAccent = adaptive("on-accent", light: 0xFFFFFF, dark: 0x182A1E)
    static let warning = adaptive("warning", light: 0x916227, dark: 0xDCB87E)
    static let danger = adaptive("danger", light: 0xB04C43, dark: 0xE9A096)
    static let shadow = adaptive("shadow", light: 0x292F2B, dark: 0x000000)

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: native(name, light: light, dark: dark))
    }

    fileprivate static let windowBackground = native("window", light: 0xF8F7F3, dark: 0x1E2420)

    private static func native(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("Recall." + name)) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
    }
}

extension View {
    func recallColors() -> some View {
        tint(RecallPalette.accent)
            .accentColor(RecallPalette.accent)
            .foregroundStyle(RecallPalette.text)
            .background(RecallPalette.background)
            .background(RecallWindowColor().allowsHitTesting(false))
    }

    func recallSidebarRow(isSelected: Bool) -> some View {
        foregroundStyle(isSelected ? RecallPalette.accent : RecallPalette.text)
            .listRowBackground(isSelected ? RecallPalette.selected : RecallPalette.sidebar)
    }
}

/// Match the native title-bar/backing color without changing window style or safe areas.
private struct RecallWindowColor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowColorView { WindowColorView() }
    func updateNSView(_ view: WindowColorView, context: Context) { view.applyColor() }

    final class WindowColorView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyColor() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColor() }
        func applyColor() { window?.backgroundColor = RecallPalette.windowBackground }
    }
}
