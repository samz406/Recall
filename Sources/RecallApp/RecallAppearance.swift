import AppKit
import SwiftUI

/// A device preference, separate from the memory archive and model configuration.
enum RecallAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    static let storageKey = "recall.appearance"
    var id: String { rawValue }
    var title: String {
        switch self { case .light: "浅色"; case .dark: "深色"; case .system: "跟随系统" }
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .system
    }
    var colorScheme: ColorScheme? {
        switch self { case .light: .light; case .dark: .dark; case .system: nil }
    }
    var nativeAppearance: NSAppearance? {
        switch self { case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua); case .system: nil }
    }
    @MainActor func applyToApplication() { NSApp.appearance = nativeAppearance }
}

struct RecallColorsModifier: ViewModifier {
    @AppStorage(RecallAppearance.storageKey) private var rawAppearance = RecallAppearance.system.rawValue
    private var appearance: RecallAppearance { RecallAppearance(rawValue: rawAppearance) ?? .system }
    func body(content: Content) -> some View {
        content
            .tint(RecallPalette.accent)
            .accentColor(RecallPalette.accent)
            .foregroundStyle(RecallPalette.text)
            .background(RecallPalette.background)
            .preferredColorScheme(appearance.colorScheme)
            .background(RecallWindowColor(appearance: appearance).allowsHitTesting(false))
            .onAppear { appearance.applyToApplication() }
            .onChange(of: rawAppearance) { _, _ in appearance.applyToApplication() }
    }
}

/// Keep AppKit controls, title bars and sheet backing in step with SwiftUI.
/// Nil releases the override so subsequent macOS appearance changes remain live.
private struct RecallWindowColor: NSViewRepresentable {
    let appearance: RecallAppearance
    func makeNSView(context: Context) -> WindowColorView { WindowColorView() }
    func updateNSView(_ view: WindowColorView, context: Context) {
        view.selection = appearance
        view.applyColor()
    }
    final class WindowColorView: NSView {
        var selection: RecallAppearance = .system
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyColor() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColor() }
        func applyColor() {
            guard let window else { return }
            let wanted = selection.nativeAppearance
            if window.appearance?.name != wanted?.name { window.appearance = wanted }
            window.backgroundColor = RecallPalette.windowBackground
        }
    }
}
