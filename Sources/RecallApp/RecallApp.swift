import RecallKit
import SwiftUI
import AppKit
import UserNotifications

@main
struct RecallApp: App {
    @NSApplicationDelegateAdaptor(RecallAppDelegate.self) private var appDelegate
    @StateObject private var model = RecallAppModel(previewState: CommandLine.arguments.contains("--layout-previews") ? RecallState() : nil)

    var body: some Scene {
        Window("Recall", id: "main") {
            RecallRootView()
                .environmentObject(model)
                .recallColors()
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 780)

        MenuBarExtra("Recall", systemImage: "brain.head.profile") {
            MenuBarPanel()
                .environmentObject(model)
                .recallColors()
        }

        Settings {
            RecallSettingsView()
                .environmentObject(model)
                .recallColors()
                .frame(width: 620, height: 560)
        }
    }
}

@MainActor
final class RecallAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--layout-previews") {
            Task { @MainActor in
                do { try await RecallLayoutPreviews.run(); exit(0) }
                catch { print("FAIL: layout previews: \(error)"); exit(1) }
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.async { Self.activateMainWindow() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let reminderID = response.notification.request.content.userInfo["reminderID"] as? String
        let weeklyReportID = response.notification.request.content.userInfo["weeklyReportID"] as? String
        let action = response.actionIdentifier
        completionHandler()
        DispatchQueue.main.async {
            if let reminderID {
                NotificationCenter.default.post(
                    name: .recallReminderAction,
                    object: nil,
                    userInfo: ["reminderID": reminderID, "action": action]
                )
                NotificationCenter.default.post(name: .recallOpenReminders, object: nil)
            }
            if let weeklyReportID {
                NotificationCenter.default.post(name: .recallOpenWeeklyReview, object: nil, userInfo: ["weeklyReportID": weeklyReportID])
            }
            Self.activateMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.activateMainWindow()
        return true
    }

    @MainActor
    static func activateMainWindow() {
        NSApp.setActivationPolicy(.regular)
        let runningApp = NSRunningApplication.current
        runningApp.activate(options: [.activateAllWindows])
        NSApp.activate()
        // WindowGroup 会在启动后的一个 run loop 内创建窗口，因此再次前置以避免窗口可见但不接收键盘事件。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            runningApp.activate(options: [.activateAllWindows])
            let mainWindow = NSApp.windows.first { window in
                window.canBecomeKey && window.styleMask.contains(.titled) && window.title.contains("Recall") && !(window is NSPanel)
            } ?? NSApp.windows.first { $0.canBecomeKey && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
            if mainWindow?.isMiniaturized == true {
                mainWindow?.deminiaturize(nil)
            }
            mainWindow?.orderFrontRegardless()
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}

private struct MenuBarPanel: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recall")
                .font(.headline)
            Text(model.state.privacy.screenCapturePaused ? "屏幕采集已暂停" : "本地优先的个人记忆")
                .font(.caption)
                .foregroundStyle(RecallPalette.secondary)
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
                openWindow(id: "main")
                DispatchQueue.main.async {
                    RecallAppDelegate.activateMainWindow()
                }
            }
            Divider()
            Button("退出 Recall") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 250)
    }
}
