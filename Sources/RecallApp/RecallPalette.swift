import AppKit
import SwiftUI

/// Warm paper × forest green, with explicit light and dark semantic roles.
@MainActor
enum RecallPalette {
    static let accent = adaptive("accent", light: 0x3B6650, dark: 0x8FCBAE)
    static let background = adaptive("background", light: 0xF7F6F2, dark: 0x1C1D1B)
    static let sidebar = adaptive("sidebar", light: 0xF1EFE8, dark: 0x151614)
    static let text = adaptive("text", light: 0x1F2A24, dark: 0xECEDE8)
    static let selected = adaptive("selected", light: 0xF1F6F3, dark: 0x26352D)
    static let surface = adaptive("surface", light: 0xFFFFFF, dark: 0x242622)
    static let secondary = adaptive("secondary", light: 0x5E6B64, dark: 0xA3A8A0)
    static let border = adaptive("border", light: 0xE3E1D8, dark: 0x34372F)
    static let onAccent = adaptive("on-accent", light: 0xFFFFFF, dark: 0x1C1D1B)
    static let warning = adaptive("warning", light: 0x916227, dark: 0xDCB87E)
    static let danger = adaptive("danger", light: 0xB04C43, dark: 0xE9A096)
    static let shadow = adaptive("shadow", light: 0x292F2B, dark: 0x000000)

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: native(name, light: light, dark: dark))
    }

    static let windowBackground = native("window", light: 0xF7F6F2, dark: 0x1C1D1B)

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
        modifier(RecallColorsModifier())
    }

    func recallSidebarRow(isSelected: Bool) -> some View {
        foregroundStyle(isSelected ? RecallPalette.accent : RecallPalette.text)
            .listRowBackground(isSelected ? RecallPalette.selected : RecallPalette.sidebar)
    }
}
