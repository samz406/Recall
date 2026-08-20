import Foundation
import RecallKit
import SwiftUI

@MainActor
final class RecallAppModel: ObservableObject {
    @Published var state = RecallState()
    @Published var isRecording = false
    @Published var isThinking = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    let storage: RecallStorage
    private let store: FileMemoryStore
    private let pipeline: CapturePipeline
    private let assistant: MemoryAssistant
    private let reminderExtractor = ReminderExtractor()
    private let notificationScheduler = LocalNotificationScheduler()

    init() {
        do {
            let storage = try RecallStorage()
            self.storage = storage
            self.store = try FileMemoryStore(storage: storage)
            self.pipeline = CapturePipeline(store: store, storage: storage)
            self.assistant = MemoryAssistant(store: store)
            Task { await refresh() }
        } catch {
            fatalError("无法初始化本地记忆库：\(error.localizedDescription)")
        }
    }

    func refresh() async {
        state = await store.snapshot()
    }

    func updateRule(_ updatedRule: EventRule) {
        var rules = state.rules
        guard let index = rules.firstIndex(where: { $0.id == updatedRule.id }) else { return }
        rules[index] = updatedRule
        persistRules(rules)
        if updatedRule.template == .dailyReview {
            Task {
                do {
                    if updatedRule.isEnabled {
                        let granted = try await notificationScheduler.requestAuthorization()
                        if granted {
                            try await notificationScheduler.scheduleDailyReview()
                            noticeMessage = "每日回顾会在每天 18:00 提醒；回顾只汇总已有记录。"
                        }
                    } else {
                        notificationScheduler.cancelDailyReview()
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func toggleRule(_ rule: EventRule, isEnabled: Bool) {
        var updated = rule
        updated.isEnabled = isEnabled
        updateRule(updated)
    }

    private func persistRules(_ rules: [EventRule]) {
        Task {
            do {
                try await store.updateRules(rules)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func requestScreenRecordingAccess() {
        let granted = ScreenCaptureService().requestScreenRecordingAccess()
        noticeMessage = granted ? "屏幕记录权限已可用。" : "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 Recall。"
    }

    func record(rule: EventRule, userText: String? = nil) {
        isRecording = true
        Task {
            defer { isRecording = false }
            do {
                let resolvedText = rule.template == .dailyReview ? makeDailyReviewText() : userText
                let record = try await pipeline.record(using: rule, userText: resolvedText)
                await refresh()
                noticeMessage = "已记录：\(record.summary ?? "无可提取文本")"
                if rule.participatesInReminders {
                    proposeReminders()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteCapture(_ capture: CaptureRecord) {
        Task {
            do {
                try await pipeline.removeCapture(capture)
                await refresh()
                noticeMessage = "已删除该记录及其关联截图。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func ask(_ question: String) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isThinking = true
        Task {
            defer { isThinking = false }
            do {
                _ = try await assistant.ask(question)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func proposeReminders() {
        let newCandidates = reminderExtractor.candidates(from: state.captures, existing: state.reminders)
        guard !newCandidates.isEmpty else { return }
        Task {
            do {
                try await store.replaceReminders(newCandidates + state.reminders)
                await refresh()
                noticeMessage = "发现 \(newCandidates.count) 项待确认提醒。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func approveReminder(_ reminder: ReminderCandidate, dueAt: Date) {
        guard dueAt > Date.now else {
            errorMessage = "请为提醒选择一个未来时间。"
            return
        }
        Task {
            do {
                var updated = reminder
                updated.dueAt = dueAt
                let granted = try await notificationScheduler.requestAuthorization()
                guard granted else {
                    throw ReminderNotificationError.authorizationRequired
                }
                try await notificationScheduler.schedule(updated)
                updated.status = .scheduled
                try await store.updateReminder(updated)
                await refresh()
                noticeMessage = "提醒已安排在 \(dueAt.formatted(date: .abbreviated, time: .shortened))。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func dismissReminder(_ reminder: ReminderCandidate) {
        Task {
            do {
                let wasScheduled = reminder.status == .scheduled
                var updated = reminder
                updated.status = .dismissed
                notificationScheduler.cancel(updated)
                try await store.updateReminder(updated)
                await refresh()
                noticeMessage = wasScheduled ? "提醒已取消。" : "已忽略该提醒候选。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updatePrivacy(_ privacy: PrivacySettings) {
        Task {
            do {
                try await store.updatePrivacy(privacy)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateLLM(configuration: LLMConfiguration, apiKey: String?) {
        Task {
            do {
                var updatedConfiguration = configuration
                if let apiKey, !apiKey.isEmpty {
                    updatedConfiguration.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                try await store.updateLLMConfiguration(updatedConfiguration)
                await refresh()
                noticeMessage = configuration.provider == .localOnly ? "已切换为本地摘要模式。" : "云端模型配置已保存；只有检索到的文本片段会在提问时发送。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 模型连接表单的提交入口。用户主动点击后，下一次“问一问”会直接使用此配置。
    func saveModelConnection(configuration: LLMConfiguration, apiKey: String, excludedBundleIdentifiers: Set<String>) {
        Task {
            do {
                let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                var updatedConfiguration = configuration
                if !cleanedKey.isEmpty {
                    updatedConfiguration.apiKey = cleanedKey
                }
                var privacy = state.privacy
                privacy.excludedBundleIdentifiers = excludedBundleIdentifiers
                privacy.cloudUseEnabled = true
                try await store.updatePrivacy(privacy)
                try await store.updateLLMConfiguration(updatedConfiguration)
                await refresh()
                noticeMessage = "模型连接已保存；下一次“问一问”将使用 \(updatedConfiguration.model)。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func makeDailyReviewText() -> String {
        let start = Calendar.current.startOfDay(for: .now)
        let todaysCaptures = state.captures.filter { $0.createdAt >= start && $0.eventTemplate != .dailyReview }
        guard !todaysCaptures.isEmpty else {
            return "每日回顾：今天还没有可汇总的显式记录。"
        }
        let lines = todaysCaptures.prefix(12).map { capture in
            let source = capture.sourceAppName ?? "未知来源"
            return "- \(source)：\(capture.summary ?? String(capture.ocrText.prefix(120)))"
        }
        return "每日回顾（\(todaysCaptures.count) 条显式记录）：\n" + lines.joined(separator: "\n")
    }

    func clearAllData() {
        let captures = state.captures
        Task {
            do {
                for capture in captures {
                    try await pipeline.removeCapture(capture)
                }
                await refresh()
                noticeMessage = "已删除全部本地记忆记录。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
