import Foundation

public struct LocalDay: Codable, Hashable, Sendable {
    public var year: Int, month: Int, day: Int
    public var timeZoneIdentifier: String
    public init(_ date: Date = .now, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year!; month = c.month!; day = c.day!; timeZoneIdentifier = timeZone.identifier
    }
    public var date: Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return c.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }
    public var label: String { date.formatted(date: .abbreviated, time: .omitted) + " · " + timeZoneIdentifier }
}
public struct TextImportMetadata: Codable, Hashable, Sendable {
    public var source: String
    public var author: String?
    public var occurredAt: Date?
    public var importedAt: Date
    public var meetingSessionID: UUID?
    public init(source: String, author: String? = nil, occurredAt: Date? = nil, importedAt: Date = .now, meetingSessionID: UUID? = nil) {
        self.source = source; self.author = author; self.occurredAt = occurredAt; self.importedAt = importedAt; self.meetingSessionID = meetingSessionID
    }
}
public struct MeetingSession: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public init(title: String, startedAt: Date = .now) { self.title = title; self.startedAt = startedAt }
}
public struct IdentityBinding: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var bundleIdentifier: String
    public var windowTitle: String
    public var sender: String
    public var confirmedAt: Date = .now
    public init(bundleIdentifier: String, windowTitle: String, sender: String) {
        self.bundleIdentifier = bundleIdentifier; self.windowTitle = windowTitle; self.sender = sender
    }
}
public struct MCPGrant: Codable, Hashable, Sendable {
    public var token: String
    public var clientName: String
    public var from: Date
    public var through: Date
    public var allowReviews: Bool
    public var appIdentifiers: Set<String>
    public init(clientName: String, from: Date, through: Date, allowReviews: Bool = true, appIdentifiers: Set<String> = []) {
        token = UUID().uuidString + UUID().uuidString
        self.clientName = clientName; self.from = from; self.through = through; self.allowReviews = allowReviews; self.appIdentifiers = appIdentifiers
    }
}
public struct WorkflowSettings: Codable, Sendable {
    public var onboardingCompleted = false
    public var identityBindings: [IdentityBinding] = []
    public var meetings: [MeetingSession] = []
    public var mcpGrant: MCPGrant?
    public init() {}
}
public enum WorkflowError: LocalizedError {
    case invalid, changed, denied
    public var errorDescription: String? {
        RecallLocalization.text(self == .invalid ? "请填写完整内容。" : self == .changed ? "来源已变化，请重新打开后重试。" : "未授权访问此内容。")
    }
}
public extension ReminderStatus {
    var isAction: Bool { self == .planned || self == .scheduled || self == .snoozed }
    var needsNotification: Bool { self == .scheduled || self == .snoozed }
}
public extension FileMemoryStore {
    func updateWorkflow(_ workflow: WorkflowSettings) throws {
        let before = state; state.workflow = workflow
        if before.workflow.identityBindings != workflow.identityBindings {
            var changed = Set<UUID>()
            for i in state.captures.indices {
                let messages = SourceNormalizer.messages(for: state.captures[i], bindings: workflow.identityBindings)
                let previousMessages = SourceNormalizer.messages(for: before.captures[i], bindings: before.workflow.identityBindings)
                if previousMessages != messages {
                    state.captures[i].sourceMessages = messages; state.captures[i].understanding = nil; changed.insert(state.captures[i].id)
                }
            }
            state.invalidateMemoryOutputs(sourceIDs: changed)
        }
        do { try persistReviewState() } catch { state = before; throw error }
    }
    @discardableResult func addToToday(id: UUID, now: Date = .now, timeZone: TimeZone = .current) throws -> Bool {
        guard let i = state.reminders.firstIndex(where: { $0.id == id }), state.reminders[i].status == .proposed else { return false }
        let row = state.reminders[i]
        let allowed = Set(EvidenceAccess.records(state).map(\.id))
        guard Set(row.sourceCaptureIDs).isSubset(of: allowed) else { throw WorkflowError.changed }
        let before = state
        state.reminders[i].status = .planned; state.reminders[i].acceptedAt = now
        state.reminders[i].plannedForDay = LocalDay(now, timeZone: timeZone)
        state.reminders[i].scheduledAt = nil; state.reminders[i].dueAt = nil; state.reminders[i].updatedAt = now
        do { try persistReviewState() } catch { state = before; throw error }
        return true
    }
    func undoAddToToday(id: UUID, acceptedAt: Date) throws {
        guard let i = state.reminders.firstIndex(where: { $0.id == id && $0.status == .planned && $0.acceptedAt == acceptedAt && $0.updatedAt == acceptedAt }) else { throw WorkflowError.changed }
        let before = state
        state.reminders[i].status = .proposed; state.reminders[i].acceptedAt = nil; state.reminders[i].plannedForDay = nil; state.reminders[i].updatedAt = .now
        do { try persistReviewState() } catch { state = before; throw error }
    }
    @discardableResult func saveText(_ text: String, title: String?, metadata: TextImportMetadata? = nil, meetingID: UUID? = nil) throws -> CaptureRecord {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 250_000 else { throw WorkflowError.invalid }
        let safe = PrivacyEngine().redact(clean)
        var record = CaptureRecord(eventTemplate: meetingID == nil ? .manualMoment : .meetingSession,
            sourceAppName: metadata?.source ?? "Recall", sourceBundleIdentifier: "im.recall.text",
            windowTitle: title, imageRelativePath: nil, contentHash: CaptureUnderstandingEngine.digest(safe),
            isRedacted: safe != clean, ocrText: safe, summary: title, tags: [], textOrigin: metadata == nil ? .userInput : .importedText)
        record.importMetadata = metadata; record.meetingSessionID = meetingID ?? metadata?.meetingSessionID
        let before = state; state.captures.append(record)
        do { try persistReviewState(indexChanged: true) } catch { state = before; throw error }
        return record
    }
    func startMeeting(title: String) throws -> MeetingSession {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkflowError.invalid }
        let session = MeetingSession(title: title)
        var workflow = state.workflow; workflow.meetings.append(session); try updateWorkflow(workflow); return session
    }
    @discardableResult func deleteMeeting(id: UUID) throws -> RecentlyDeletedMemory? {
        let ids = Set(state.captures.filter { $0.meetingSessionID == id }.map(\.id))
        if !ids.isEmpty { return try moveCapturesToRecentlyDeleted(ids: ids, reason: .noLongerNeeded, suppressSimilar: false) }
        var workflow = state.workflow; workflow.meetings.removeAll { $0.id == id }; try updateWorkflow(workflow); return nil
    }
    func finishMeeting(id: UUID) throws {
        var workflow = state.workflow
        guard let i = workflow.meetings.firstIndex(where: { $0.id == id && $0.endedAt == nil }) else { throw WorkflowError.changed }
        workflow.meetings[i].endedAt = .now; try updateWorkflow(workflow)
    }
}
