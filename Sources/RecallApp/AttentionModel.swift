import AppKit
import Foundation
import RecallKit

/// Recall's own interruptions share one daily budget; reminders the user scheduled are not counted.
extension RecallAppModel {
    /// True when a system notification may be posted. Otherwise the notice is kept in the in-app inbox.
    func admitAttention(_ notice: AttentionNotice) async -> Bool {
        do {
            let admitted = try await store.admitAttention(notice)
            let snapshot = await store.snapshot()
            state.attentionInbox = snapshot.attentionInbox; state.attentionSettings = snapshot.attentionSettings
            if !admitted { recordDiagnostic(.info, source: "Attention", message: "今日主动通知已达上限，已放入收件箱", metadata: ["kind": notice.kind.rawValue]) }
            return admitted
        } catch {
            recordError(error, source: "Attention", message: "通知额度记录失败，本次不发送通知")
            return false
        }
    }
    func dismissAttention(_ ids: Set<UUID>) {
        Task { do { try await store.dismissAttention(ids); state = await store.snapshot() } catch { recordError(error, source: "Attention", message: "清除收件箱失败") } }
    }
    func openAttention(_ notice: AttentionNotice) {
        if let id = notice.dailyReviewID { destination = .daily(id) }
        else if let id = notice.weeklyReportID { destination = .review(id) }
        dismissAttention([notice.id])
    }
    func setAttentionLimit(_ limit: Int) {
        Task { do { try await store.updateAttentionSettings(limit: limit); state = await store.snapshot() } catch { recordError(error, source: "Attention", message: "保存通知上限失败") } }
    }

    // MARK: "About me" opt-in

    /// Asked once, after the first saved review, and only when a model is connected.
    var shouldAskAboutPersona: Bool {
        !isPreview && state.personaProfileSettings.askedAt == nil && !state.personaProfileSettings.enabled
            && state.privacy.cloudUseEnabled && state.llmConfiguration.hasCredential && !state.dailySummaries.isEmpty
    }
    func answerPersonaQuestion(enable: Bool) {
        Task {
            do { try await store.markPersonaAsked(enable: enable); state = await store.snapshot(); if enable { refreshPersonaProfileIfNeeded() } }
            catch { recordError(error, source: "PersonaProfile", message: "保存“关于我”选择失败") }
        }
    }

    // MARK: Meeting brief

    func setMeetingBrief(enabled: Bool, minutesBefore: Int) {
        Task {
            if enabled, !calendarReader.authorized() {
                guard await calendarReader.requestAccess() else {
                    noticeMessage = RecallLocalization.both("未获得日历权限，会前简报保持关闭。可在系统设置 → 隐私与安全性 → 日历中允许。",
                        "Calendar access was not granted; meeting briefs stay off. Allow it in System Settings → Privacy & Security → Calendars.")
                    return
                }
            }
            do { try await store.updateMeetingBriefSettings(enabled: enabled, minutesBefore: minutesBefore); state = await store.snapshot(); armMeetingBriefs() }
            catch { recordError(error, source: "MeetingBrief", message: "保存会前简报设置失败") }
        }
    }

    /// Checks the calendar once a minute while enabled. Turning the setting off stops the timer.
    func armMeetingBriefs() {
        meetingBriefTimer?.invalidate(); meetingBriefTimer = nil
        guard !isPreview, state.meetingBriefSettings.enabled else { return }
        meetingBriefTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkMeetingBriefs() }
        }
        checkMeetingBriefs()
    }

    private func checkMeetingBriefs() {
        let settings = state.meetingBriefSettings
        guard settings.enabled, calendarReader.authorized() else { return }
        let now = Date.now
        let events = calendarReader.events(from: now, to: now.addingTimeInterval(TimeInterval(settings.minutesBefore * 60 + 60)))
        guard let event = MeetingBriefEngine.due(events, settings: settings, now: now).first else { return }
        let brief = MeetingBriefEngine.brief(for: event, in: state)
        Task {
            do { try await store.markMeetingBriefed(event.key); state = await store.snapshot() }
            catch { recordError(error, source: "MeetingBrief", message: "记录会前简报失败"); return }
            // A brief with nothing behind it is not worth an interruption.
            guard !brief.records.isEmpty || !brief.openReminders.isEmpty else { return }
            meetingBriefToShow = brief
            let notice = AttentionNotice(kind: .meetingBrief, title: RecallLocalization.both("会前简报：", "Before your meeting: ") + event.title,
                body: RecallLocalization.both("找到 \(brief.records.count) 条相关记录", "\(brief.records.count) related records"))
            if await admitAttention(notice) {
                do { try await notificationScheduler.deliverNotice(title: notice.title, body: notice.body, identifier: "im.recall.app.meeting-brief." + event.key) }
                catch { recordError(error, source: "MeetingBrief", message: "会前简报通知投递失败") }
            }
        }
    }
}
