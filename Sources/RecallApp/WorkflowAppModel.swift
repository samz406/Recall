import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RecallKit

extension RecallAppModel {
    func resolveEvidenceURL() {
        guard let url = pendingEvidenceURL, !isLoadingSavedState else { return }
        pendingEvidenceURL = nil
        if let id = EvidenceLinkRouter.captureID(url), let record = EvidenceAccess.records(state).first(where: { $0.id == id }) { sourceToOpen = record }
        else { noticeMessage = RecallLocalization.both("来源不存在或已不可用。", "This source is no longer available.") }
    }

    func configureShortcuts() {
        guard !isLoadingSavedState, !isPreview, !isRecordingShortcut else { return }
        let record = GlobalShortcutBinding.load("record", fallback: .record), ask = GlobalShortcutBinding.load("ask", fallback: .ask)
        let identity = "\(record)\(ask)"
        guard shortcutConfigurationID != identity else { return }; shortcutConfigurationID = identity
        shortcutsReady = globalShortcuts.configure(record: record, ask: ask, onRecord: { [weak self] in
            guard let self, !self.isRecording, let rule = self.state.rules.first(where: { $0.template == .manualMoment && $0.isEnabled }) else { return }
            self.record(rule: rule)
        }, onAsk: { [weak self] in
            self?.openAskRequested = true
            self?.openMainWindow?()
        })
    }
    func setShortcutRecording(_ recording: Bool) {
        isRecordingShortcut = recording
        if recording { globalShortcuts.stop(); shortcutConfigurationID = nil }
        else { configureShortcuts() }
    }
    func saveShortcut(_ binding: GlobalShortcutBinding, action: String) {
        guard binding.modifiers & 0x1100 != 0 else { return }
        if let data = try? JSONEncoder().encode(binding) { UserDefaults.standard.set(data, forKey: "recall.shortcut." + action) }
        shortcutConfigurationID = nil; configureShortcuts()
    }
    func addActionToToday(_ id: UUID) {
        Task {
            do {
                if try await store.addToToday(id: id) {
                    state = await store.snapshot(); addedTodayUndo = state.reminders.first { $0.id == id }
                    noticeMessage = RecallLocalization.text("已加入今天")
                }
            } catch { noticeMessage = error.localizedDescription }
        }
    }
    func undoToday() {
        guard let row = addedTodayUndo, let accepted = row.acceptedAt else { return }
        Task {
            do { try await store.undoAddToToday(id: row.id, acceptedAt: accepted); addedTodayUndo = nil; await refresh() }
            catch { noticeMessage = error.localizedDescription }
        }
    }
    func exportAnswer(_ message: ConversationMessage, toFile: Bool) {
        Task {
            do {
                let result = try EvidenceExportBuilder.answer(message, state: await store.snapshot())
                if toFile {
                    let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Recall-answer.md"
                    guard await panel.begin() == .OK, let url = panel.url else { return }
                    guard EvidenceExportBuilder.validate(result, state: await store.snapshot()) else { throw WorkflowError.changed }
                    try result.markdown.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    guard EvidenceExportBuilder.validate(result, state: await store.snapshot()) else { throw WorkflowError.changed }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.markdown, forType: .string)
                }
                noticeMessage = toFile ? RecallLocalization.both("已导出 Markdown。", "Markdown exported.") : RecallLocalization.text("已复制。")
            } catch { noticeMessage = error.localizedDescription }
        }
    }
    func finishOnboarding() {
        Task { do { var workflow = state.workflow; workflow.onboardingCompleted = true; try await store.updateWorkflow(workflow); showsOnboarding = false; state = await store.snapshot() } catch { noticeMessage = error.localizedDescription } }
    }
    func saveTextEntry(_ text: String, title: String, imported: Bool, source: String, author: String, occurredAt: Date?, meetingID: UUID?) {
        Task {
            do {
                let metadata = imported ? TextImportMetadata(source: source, author: author.isEmpty ? nil : author, occurredAt: occurredAt, meetingSessionID: meetingID) : nil
                let record = try await store.saveText(text, title: title.isEmpty ? nil : title, metadata: metadata, meetingID: meetingID)
                showsTextEntry = false; await refresh(); sourceToOpen = record
            } catch { noticeMessage = error.localizedDescription }
        }
    }
    func saveIdentity(captureID: UUID, sender: String) {
        guard let source = state.captures.first(where: { $0.id == captureID }), let bundle = source.sourceBundleIdentifier,
              let window = source.windowTitle, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                var workflow = state.workflow
                workflow.identityBindings.removeAll { $0.bundleIdentifier == bundle && $0.windowTitle == window }
                workflow.identityBindings.append(IdentityBinding(bundleIdentifier: bundle, windowTitle: window, sender: sender.trimmingCharacters(in: .whitespacesAndNewlines)))
                try await store.updateWorkflow(workflow); await refresh()
            } catch { noticeMessage = error.localizedDescription }
        }
    }
    func removeIdentity(_ id: UUID) {
        Task { do { var workflow = state.workflow; workflow.identityBindings.removeAll { $0.id == id }; try await store.updateWorkflow(workflow); await refresh() } catch { noticeMessage = error.localizedDescription } }
    }
    func setMCP(client: String, from: Date, through: Date, reviews: Bool, appIdentifiers: Set<String>) {
        Task {
            do {
                guard !client.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, from <= through else { throw WorkflowError.invalid }
                var workflow = state.workflow; workflow.mcpGrant = MCPGrant(clientName: client, from: from, through: through, allowReviews: reviews, appIdentifiers: appIdentifiers)
                try await store.updateWorkflow(workflow); state = await store.snapshot()
            } catch { noticeMessage = error.localizedDescription }
        }
    }
    func revokeMCP() {
        Task { do { var workflow = state.workflow; workflow.mcpGrant = nil; try await store.updateWorkflow(workflow); state = await store.snapshot() } catch { noticeMessage = error.localizedDescription } }
    }
    func startMeeting(_ title: String) {
        guard !isRecording else { return }
        guard let target = lastExternalTarget else { noticeMessage = RecallLocalization.both("请先切换到会议窗口，再回到 Recall。", "Switch to the meeting window, then return to Recall."); return }
        isRecording = true
        Task {
            defer { isRecording = false }
            do {
                let meeting = try await store.startMeeting(title: title)
                var rule = EventRule.defaults().first { $0.template == .meetingSession }!; rule.isEnabled = true
                _ = try await pipeline.record(using: rule, meetingID: meeting.id, targetOverride: target)
                await refresh()
            } catch { noticeMessage = error.localizedDescription; await refresh() }
        }
    }
    func endMeeting(_ id: UUID) {
        guard !isRecording, let target = lastExternalTarget else { return }
        isRecording = true
        Task {
            defer { isRecording = false }
            do {
                var rule = EventRule.defaults().first { $0.template == .meetingSession }!; rule.isEnabled = true
                _ = try await pipeline.record(using: rule, meetingID: id, targetOverride: target)
                try await store.finishMeeting(id: id); await refresh()
            } catch { noticeMessage = error.localizedDescription }
        }
    }
    func deleteMeeting(_ id: UUID) {
        Task {
            do {
                deletionUndoNotice = try await store.deleteMeeting(id: id)
                await refresh()
            } catch { noticeMessage = error.localizedDescription }
        }
    }
    func deleteModelKey() {
        Task { do { try await store.deleteModelCredential(); await refresh() } catch { noticeMessage = error.localizedDescription } }
    }
}
extension GlobalShortcutBinding {
    static func load(_ action: String, fallback: Self) -> Self {
        guard let data = UserDefaults.standard.data(forKey: "recall.shortcut." + action), let result = try? JSONDecoder().decode(Self.self, from: data) else { return fallback }; return result
    }
}
