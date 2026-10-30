import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(RecallAppearance.storageKey) private var rawAppearance = RecallAppearance.system.rawValue
    private var selection: RecallAppearance { RecallAppearance(rawValue: rawAppearance) ?? .system }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("外观").font(.headline).foregroundStyle(RecallPalette.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("界面主题").font(.system(size: 18, weight: .semibold))
                Text("选择 Recall 的显示外观。").font(.subheadline).foregroundStyle(RecallPalette.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { themeCards(minimumWidth: 138) }
                VStack(spacing: 8) { themeCards(minimumWidth: 0, compactRows: true) }
            }
            Label("跟随系统时，Recall 会随 macOS 的外观设置自动切换。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(RecallPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.recallSurface(padding: 28)
    }

    @ViewBuilder private func themeCards(minimumWidth: CGFloat, compactRows: Bool = false) -> some View {
        ForEach(RecallAppearance.allCases) { appearance in
            Button {
                rawAppearance = appearance.rawValue
            } label: {
                Group {
                    if compactRows {
                        HStack(spacing: 14) {
                            AppearanceThumbnail(appearance: appearance).frame(width: 88, height: 57)
                            choiceLabel(appearance)
                            Spacer(minLength: 0)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            AppearanceThumbnail(appearance: appearance).aspectRatio(1.55, contentMode: .fit)
                            choiceLabel(appearance)
                        }
                    }
                }.padding(compactRows ? 10 : 12).frame(minWidth: minimumWidth, maxWidth: .infinity)
                    .background(selection == appearance ? RecallPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(selection == appearance ? RecallPalette.accent : RecallPalette.border, lineWidth: selection == appearance ? 2 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain)
                .accessibilityLabel(appearance.title + "主题")
                .accessibilityAddTraits(selection == appearance ? .isSelected : [])
        }
    }
    private func choiceLabel(_ appearance: RecallAppearance) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(selection == appearance ? RecallPalette.accent : .clear)
                Circle().stroke(selection == appearance ? RecallPalette.accent : RecallPalette.secondary.opacity(0.55), lineWidth: 1.5)
                if selection == appearance {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(RecallPalette.onAccent)
                }
            }.frame(width: 18, height: 18)
            Text(appearance.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(RecallPalette.text)
        }
    }
}

/// Literal colors intentionally stay independent of the surrounding application theme.
private struct AppearanceThumbnail: View {
    let appearance: RecallAppearance
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                window(dark: appearance == .dark)
                if appearance == .system {
                    window(dark: true).clipShape(DiagonalHalf())
                }
            }.clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xD8D7CD).opacity(0.7), lineWidth: 0.5))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityHidden(true)
    }
    private func window(dark: Bool) -> some View {
        GeometryReader { geometry in
            let small = geometry.size.width < 130
            let sidebarWidth = geometry.size.width * 0.37
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: dark ? 0x8FCBAE : 0x3B6650)).frame(width: max(1, min(30, sidebarWidth - 10)), height: small ? 3 : 5)
                    ForEach(0..<2) { _ in RoundedRectangle(cornerRadius: 3).fill(Color(hex: dark ? 0x4E524A : 0xCFCEC4)).frame(width: max(1, min(26, sidebarWidth - 12)), height: small ? 3 : 5) }
                    Spacer(minLength: 0)
                }.padding(small ? 5 : 8).frame(maxHeight: .infinity).frame(width: sidebarWidth).background(Color(hex: dark ? 0x151614 : 0xEEECE4))
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: dark ? 0x4E524A : 0xCFCEC4)).frame(width: 30, height: 7)
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: dark ? 0x2D302A : 0xFFFFFF)).frame(maxHeight: .infinity)
                    RoundedRectangle(cornerRadius: 5).fill(Color(hex: dark ? 0x2D302A : 0xFFFFFF)).frame(height: small ? 10 : 19)
                }.padding(small ? 6 : 10).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: dark ? 0x1C1D1B : 0xF7F6F2))
            }
        }
    }
    private struct DiagonalHalf: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.width * 0.56, y: 0))
                path.addLine(to: CGPoint(x: rect.maxX, y: 0))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}

private extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
