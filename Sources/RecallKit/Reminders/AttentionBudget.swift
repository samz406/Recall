import Foundation

/// Limits how often Recall interrupts on its own. User-scheduled reminders are never limited:
/// the user asked for those. Everything Recall decides to say by itself shares one daily budget.
public struct AttentionSettings: Codable, Hashable, Sendable {
    public static let defaultDailyLimit = 2
    /// Proactive notifications per local day. 0 sends everything to the in-app inbox.
    public var dailyProactiveLimit: Int = AttentionSettings.defaultDailyLimit
    public var sentDay: LocalDay? = nil
    public var sentCount: Int = 0
    public init() {}
}

public struct AttentionNotice: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case dailyReview, periodReview, meetingBrief, morningResume, persona }
    public var id = UUID()
    public var kind: Kind
    public var title: String
    public var body: String
    public var createdAt: Date
    public var dailyReviewID: UUID?
    public var weeklyReportID: UUID?
    public init(kind: Kind, title: String, body: String, createdAt: Date = .now, dailyReviewID: UUID? = nil, weeklyReportID: UUID? = nil) {
        self.kind = kind; self.title = title; self.body = body; self.createdAt = createdAt
        self.dailyReviewID = dailyReviewID; self.weeklyReportID = weeklyReportID
    }
}

public enum AttentionBudget {
    public static let inboxLimit = 30

    /// Reserves one interruption if the budget allows it; otherwise files the notice in the inbox.
    /// Returns true when the caller may post a system notification.
    public static func admit(_ notice: AttentionNotice, in state: inout RecallState, now: Date = .now, timeZone: TimeZone = .current) -> Bool {
        let today = LocalDay(now, timeZone: timeZone)
        if state.attentionSettings.sentDay != today { state.attentionSettings.sentDay = today; state.attentionSettings.sentCount = 0 }
        if state.attentionSettings.sentCount < max(0, state.attentionSettings.dailyProactiveLimit) {
            state.attentionSettings.sentCount += 1
            return true
        }
        state.attentionInbox.removeAll { $0.kind == notice.kind && $0.dailyReviewID == notice.dailyReviewID && $0.weeklyReportID == notice.weeklyReportID && notice.dailyReviewID != nil }
        state.attentionInbox.insert(notice, at: 0)
        if state.attentionInbox.count > inboxLimit { state.attentionInbox.removeLast(state.attentionInbox.count - inboxLimit) }
        return false
    }
}

public extension FileMemoryStore {
    func admitAttention(_ notice: AttentionNotice, now: Date = .now) throws -> Bool {
        let before = state
        let admitted = AttentionBudget.admit(notice, in: &state, now: now)
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = before; throw error }
        return admitted
    }
    func dismissAttention(_ ids: Set<UUID>) throws {
        let before = state
        state.attentionInbox.removeAll { ids.contains($0.id) }
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = before; throw error }
    }
    func updateAttentionSettings(limit: Int) throws {
        let before = state
        state.attentionSettings.dailyProactiveLimit = min(max(limit, 0), 10)
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = before; throw error }
    }
    func recordReviewAttempt(_ metric: ReviewAttemptMetric) throws {
        let before = state
        state.reviewAttemptMetrics.append(metric)
        if state.reviewAttemptMetrics.count > 200 { state.reviewAttemptMetrics.removeFirst(state.reviewAttemptMetrics.count - 200) }
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = before; throw error }
    }
    func markPersonaAsked(enable: Bool, now: Date = .now) throws {
        let before = state
        state.personaProfileSettings.askedAt = now
        if enable { state.personaProfileSettings.enabled = true; state.personaProfileRevision = UUID() }
        do { try persistReviewState(invalidateAnalysis: false) } catch { state = before; throw error }
    }
}
