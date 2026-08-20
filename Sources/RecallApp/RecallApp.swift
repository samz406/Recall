import RecallKit
import SwiftUI

@main
struct RecallApp: App {
    @StateObject private var model = RecallAppModel()

    var body: some Scene {
        WindowGroup("Recall · 个人记忆") {
            RecallRootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 780)

        MenuBarExtra("Recall", systemImage: "brain.head.profile") {
            MenuBarPanel()
                .environmentObject(model)
        }

        Settings {
            RecallSettingsView()
                .environmentObject(model)
                .frame(width: 620, height: 560)
        }
    }
}

private struct MenuBarPanel: View {
    @EnvironmentObject private var model: RecallAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recall")
                .font(.headline)
            Text(model.state.privacy.screenCapturePaused ? "屏幕采集已暂停" : "本地优先的个人记忆")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("记录此刻  ⌥↩") {
                if let rule = model.state.rules.first(where: { $0.template == .manualMoment }) {
                    model.record(rule: rule)
                }
            }
            .disabled(model.state.privacy.screenCapturePaused || model.isRecording)
            Button(model.state.privacy.screenCapturePaused ? "恢复屏幕采集" : "暂停屏幕采集") {
                var privacy = model.state.privacy
                privacy.screenCapturePaused.toggle()
                model.updatePrivacy(privacy)
            }
            Button("打开 Recall") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("退出 Recall") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 250)
    }
}
