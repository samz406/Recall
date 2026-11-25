import Foundation

/// Read-only views computed from saved records on demand. Nothing here is persisted, calls a model,
/// or reads the screen, so deleting a source removes it from every view on the next render.
public enum LocalBriefing {
    /// Records that may appear in any brief: the same filter used for exports and answers.
    static func usable(_ state: RecallState) -> [CaptureRecord] { EvidenceAccess.records(state) }

    // MARK: Offline daily review

    public struct AppGroup: Identifiable, Sendable, Equatable {
        public var id: String { app }
        public var app: String
        public var count: Int
        public var first: Date
        public var last: Date
        public var titles: [String]
        public var sourceIDs: [UUID]
    }

    public struct ActionLead: Identifiable, Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var sourceIDs: [UUID]
    }

    public struct OfflineDay: Sendable, Equatable {
        public var day: Date
        public var recordCount: Int
        public var groups: [AppGroup]
        public var actionLeads: [ActionLead]
        public var notes: [(id: UUID, text: String)]
        public static func == (lhs: OfflineDay, rhs: OfflineDay) -> Bool {
            lhs.day == rhs.day && lhs.recordCount == rhs.recordCount && lhs.groups == rhs.groups && lhs.actionLeads == rhs.actionLeads
                && lhs.notes.map(\.id) == rhs.notes.map(\.id)
        }
    }

    /// A review that needs no model: records grouped by app, the rule-based action leads Recall already
    /// uses for reminders, and the user's own notes. Leads are suggestions, never scheduled reminders.
    public static func offlineDay(_ day: Date, in state: RecallState, calendar: Calendar = .current) -> OfflineDay {
        let start = calendar.startOfDay(for: day)
        let records = usable(state).filter { calendar.isDate($0.createdAt, inSameDayAs: start) }.sorted { $0.createdAt < $1.createdAt }
        var buckets: [String: [CaptureRecord]] = [:]
        for record in records { buckets[record.sourceAppName ?? RecallLocalization.both("未知应用", "Unknown app"), default: []].append(record) }
        var groups: [AppGroup] = []
        for (app, rows) in buckets {
            groups.append(AppGroup(app: app, count: rows.count, first: rows[0].createdAt, last: rows[rows.count - 1].createdAt,
                                   titles: distinctTitles(rows), sourceIDs: rows.map(\.id)))
        }
        groups.sort { $0.count == $1.count ? $0.app < $1.app : $0.count > $1.count }
        let closed = state.reminders.filter { [.completed, .cancelled, .dismissed].contains($0.status) }
        let leads = ReminderExtractor().candidates(from: records, existing: closed, now: start.addingTimeInterval(86_399),
                                                   learningProfile: state.reminderLearningProfile)
            .prefix(5).map { ActionLead(id: $0.id, title: $0.title, sourceIDs: $0.sourceCaptureIDs) }
        let notes = records.compactMap { record in record.userNote.map { (id: record.id, text: $0) } }
        return OfflineDay(day: start, recordCount: records.count, groups: groups, actionLeads: Array(leads), notes: notes)
    }

    private static func distinctTitles(_ rows: [CaptureRecord]) -> [String] {
        var seen = Set<String>(), titles: [String] = []
        for row in rows {
            let raw: String = row.windowTitle?.isEmpty == false ? row.windowTitle! : (row.summary ?? "")
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, seen.insert(title).inserted { titles.append(String(title.prefix(80))) }
            if titles.count == 4 { break }
        }
        return titles
    }

    // MARK: Resume card

    public struct ResumeItem: Identifiable, Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case lastRecord, openTopic, dueReminder, waitingOnOthers }
        public var id: String
        public var kind: Kind
        public var title: String
        public var detail: String
        public var destination: MemorySearchDestination
        public var date: Date
    }

    /// "Pick up where you stopped": the last thing recorded on the previous active day, open topics,
    /// reminders due today, and things others still owe the user. At most five items.
    public static func resume(in state: RecallState, matters: [MatterFile], now: Date = .now, calendar: Calendar = .current) -> [ResumeItem] {
        let today = calendar.startOfDay(for: now)
        let records = usable(state)
        var items: [ResumeItem] = []
        if let previous = records.filter({ $0.createdAt < today }).max(by: { $0.createdAt < $1.createdAt }) {
            // The summary says what happened; a window title is often just the app name
            // ("WeChat"), which told the reader nothing about where they stopped.
            let title = previous.userNote ?? previous.summary ?? previous.windowTitle ?? RecallLocalization.both("上一条记录", "Last record")
            items.append(ResumeItem(id: "last-" + previous.id.uuidString, kind: .lastRecord, title: String(title.prefix(90)),
                detail: (previous.sourceAppName ?? "") + " · " + Self.relativeStamp(previous.createdAt),
                destination: .record(previous.id), date: previous.createdAt))
        }
        let horizon = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        for file in matters where file.latest.status.isOpenMatter && file.latest.date >= horizon && !file.needsStatusUpdate(at: now, calendar: calendar) {
            // "Open" only means the last event was not marked done. Without a stated next
            // step the topic is an activity log, not something to pick up again — unless
            // its last event is explicitly pending or blocked.
            let actionable = file.latest.status == .pending || file.latest.status == .blocked || file.resumeNextAction != nil
            guard actionable else { continue }
            items.append(ResumeItem(id: "topic-" + file.id, kind: .openTopic, title: file.title,
                detail: file.resumeNextAction ?? Self.statusDetail(file.latest.status), destination: .topic(file.id), date: file.latest.date))
        }
        for reminder in state.reminders where reminder.status.isAction {
            guard let due = ReminderTimeline.effectiveDueAt(reminder) ?? reminder.plannedForDay?.date,
                  due < (calendar.date(byAdding: .day, value: 1, to: today) ?? now) else { continue }
            items.append(ResumeItem(id: "reminder-" + reminder.id.uuidString, kind: .dueReminder, title: reminder.title,
                detail: due < now ? RecallLocalization.both("已到期", "Due") : due.formatted(date: .omitted, time: .shortened),
                destination: .reminder(reminder.id), date: due))
        }
        for owed in commitments(in: state, now: now).filter({ $0.direction == .owedToMe }).prefix(2) {
            items.append(ResumeItem(id: "owed-" + owed.id, kind: .waitingOnOthers, title: owed.title,
                detail: RecallLocalization.both("等待对方：", "Waiting on: ") + owed.counterpart, destination: .record(owed.sourceID), date: owed.date))
        }
        let rank: [ResumeItem.Kind: Int] = [.dueReminder: 0, .lastRecord: 1, .openTopic: 2, .waitingOnOthers: 3]
        return Array(items.sorted { rank[$0.kind]! == rank[$1.kind]! ? $0.date > $1.date : rank[$0.kind]! < rank[$1.kind]! }.prefix(5))
    }

    /// "昨天 19:20" reads better on a resume card than a full calendar date.
    private static func relativeStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = RecallLocalization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    private static func statusDetail(_ status: WorkEpisodeStatus) -> String {
        switch status {
        case .pending: RecallLocalization.both("明确待办", "Open action")
        case .blocked: RecallLocalization.both("遇到阻碍", "Blocked")
        case .progressed: RecallLocalization.both("正在推进", "In progress")
        case .completed: RecallLocalization.both("记录为已完成", "Completed")
        case .explored: RecallLocalization.both("相关记录", "Related record")
        }
    }

    // MARK: Commitments between the user and others

    public struct Commitment: Identifiable, Sendable, Equatable {
        public enum Direction: Sendable, Equatable { case iOwe, owedToMe }
        public var id: String
        public var direction: Direction
        public var title: String
        public var counterpart: String
        public var date: Date
        public var deadline: String?
        public var sourceID: UUID
    }

    /// Pending commitments from understood records only. Speaker and actor come from the model's checked
    /// understanding; plain OCR is never guessed. The counterpart is the conversation window, not a person.
    public static func commitments(in state: RecallState, now: Date = .now, limit: Int = 30) -> [Commitment] {
        var result: [Commitment] = [], seen = Set<String>()
        let closedSubjects = Set(state.captures.flatMap { $0.understanding?.facts ?? [] }
            .filter { [.completed, .cancelled].contains($0.status) }.map { $0.subject.lowercased() })
        for record in usable(state).sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let understanding = record.understanding, CaptureUnderstandingEngine.isCurrent(understanding, in: state) else { continue }
            for fact in understanding.facts where fact.status == .pending && (fact.condition?.isEmpty ?? true) && fact.kind != .reference {
                let direction: Commitment.Direction
                if fact.kind == .commitment && fact.actor == .user { direction = .iOwe }
                else if (fact.kind == .commitment || fact.kind == .request) && fact.actor == .other { direction = .owedToMe }
                else if fact.kind == .request && fact.speaker == .other && fact.actor != .other { direction = .iOwe }
                else { continue }
                let key = fact.subject.lowercased()
                guard !closedSubjects.contains(key), seen.insert(key).inserted else { continue }
                let counterpart = record.windowTitle?.isEmpty == false ? record.windowTitle! : (record.sourceAppName ?? RecallLocalization.both("对方", "Other party"))
                result.append(Commitment(id: record.id.uuidString + fact.id, direction: direction, title: fact.subject,
                    counterpart: String(counterpart.prefix(60)), date: record.createdAt, deadline: fact.deadline?.text, sourceID: record.id))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    // MARK: Week at a glance

    public struct WeekGlance: Sendable, Equatable {
        public var recordCount: Int
        public var topApp: String?
        public var topAppShare: Double
        public var previousTopAppShare: Double?
        public var activeDays: Int
        /// Plain sentence, counted from records. It says nothing about time spent.
        public var sentence: String
    }

    /// One counted observation for a period: which app the user recorded most often, compared with the
    /// period before. Returns nil with fewer than five records, because a share of three is noise.
    public static func glance(_ period: ReviewPeriod, in state: RecallState, calendar: Calendar = .current) -> WeekGlance? {
        let records = usable(state)
        func rows(_ start: Date, _ end: Date) -> [CaptureRecord] { records.filter { $0.createdAt >= start && $0.createdAt < end } }
        let current = rows(period.start, period.end)
        guard current.count >= 5 else { return nil }
        func top(_ list: [CaptureRecord]) -> (String, Double)? {
            let counts = Dictionary(grouping: list, by: { $0.sourceAppName ?? "" }).filter { !$0.key.isEmpty }.mapValues(\.count)
            guard let best = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) else { return nil }
            return (best.key, Double(best.value) / Double(max(list.count, 1)))
        }
        let length = period.end.timeIntervalSince(period.start)
        let previous = rows(period.start.addingTimeInterval(-length), period.start)
        let now = top(current), before = previous.count >= 5 ? previous.filter { $0.sourceAppName == now?.0 }.count : nil
        let previousShare = before.map { Double($0) / Double(previous.count) }
        let days = Set(current.map { calendar.startOfDay(for: $0.createdAt) }).count
        var sentence = RecallLocalization.both("这段时间保存了 \(current.count) 条记录，分布在 \(days) 天。",
                                               "\(current.count) records saved across \(days) days.")
        if let now {
            let percent = Int((now.1 * 100).rounded())
            sentence += RecallLocalization.both("其中 \(percent)% 来自 \(now.0)", " \(percent)% came from \(now.0)")
            if let previousShare {
                let delta = Int(((now.1 - previousShare) * 100).rounded())
                if abs(delta) >= 10 {
                    sentence += delta > 0 ? RecallLocalization.both("，比上一段多 \(delta) 个百分点", ", up \(delta) points from the period before")
                                          : RecallLocalization.both("，比上一段少 \(-delta) 个百分点", ", down \(-delta) points from the period before")
                }
            }
            sentence += RecallLocalization.both("。按记录条数统计，不代表时长。", ". Counted by records, not time spent.")
        }
        return WeekGlance(recordCount: current.count, topApp: now?.0, topAppShare: now?.1 ?? 0, previousTopAppShare: previousShare,
                          activeDays: days, sentence: sentence)
    }

    // MARK: Related history for the current window

    /// "How did I do this last time": records whose text shares terms with the window title (and optional
    /// selected text). Same app first. Purely local; the current window itself is not recorded.
    public static func related(title: String, bundleIdentifier: String?, in state: RecallState, now: Date = .now, limit: Int = 8) -> [CaptureRecord] {
        let terms = Array(QuestionTerms.topicTerms(title).filter { $0.count >= 2 }.prefix(12))
        guard !terms.isEmpty else { return [] }
        let scored = usable(state).compactMap { record -> (CaptureRecord, Double)? in
            guard now.timeIntervalSince(record.createdAt) > 120 else { return nil }
            let haystack = (record.searchableText + " " + (record.windowTitle ?? "")).lowercased()
            let hits = terms.filter { haystack.contains($0.lowercased()) }.count
            guard Double(hits) >= max(1, Double(terms.count) * 0.34) else { return nil }
            let sameApp = bundleIdentifier != nil && record.sourceBundleIdentifier == bundleIdentifier ? 0.5 : 0
            return (record, Double(hits) / Double(terms.count) + sameApp)
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.createdAt > $1.0.createdAt : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // MARK: Review reliability

    public struct ReviewStats: Sendable, Equatable {
        public var attempts: Int
        public var succeeded: Int
        public var partial: Int
        public var failed: Int
        public var cancelled: Int
        public var medianSeconds: Int?
        public var successRate: Double? { attempts - cancelled > 0 ? Double(succeeded + partial) / Double(attempts - cancelled) : nil }
    }
}

/// One finished review attempt. Stored without any review text, source, model output or error message.
public struct ReviewAttemptMetric: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case daily, period }
    public enum Outcome: String, Codable, Sendable { case succeeded, partial, failed, cancelled }
    public var kind: Kind
    public var outcome: Outcome
    public var finishedAt: Date
    public var milliseconds: Int
    public init(kind: Kind, outcome: Outcome, finishedAt: Date = .now, milliseconds: Int) {
        self.kind = kind; self.outcome = outcome; self.finishedAt = finishedAt; self.milliseconds = max(0, milliseconds)
    }
}

public extension LocalBriefing {
    static func reviewStats(_ metrics: [ReviewAttemptMetric], kind: ReviewAttemptMetric.Kind? = nil, since: Date) -> ReviewStats {
        let rows = metrics.filter { (kind == nil || $0.kind == kind) && $0.finishedAt >= since }
        let finished = rows.filter { $0.outcome == .succeeded || $0.outcome == .partial }.map(\.milliseconds).sorted()
        return ReviewStats(attempts: rows.count, succeeded: rows.filter { $0.outcome == .succeeded }.count,
            partial: rows.filter { $0.outcome == .partial }.count, failed: rows.filter { $0.outcome == .failed }.count,
            cancelled: rows.filter { $0.outcome == .cancelled }.count,
            medianSeconds: finished.isEmpty ? nil : finished[finished.count / 2] / 1000)
    }
}
