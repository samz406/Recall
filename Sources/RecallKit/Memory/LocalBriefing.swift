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
        public enum Kind: Sendable, Equatable { case openMatter, missingReview, dueReminder, waitingOnOthers }
        public var id: String
        public var kind: Kind
        public var title: String
        public var detail: String
        public var destination: MemorySearchDestination
        /// For `missingReview`, the day to generate.
        public var date: Date
        public enum Basis: Int, Sendable { case handwritten, action, progress }
        public var topic: String? = nil
        public var status: WorkEpisodeStatus? = nil
        public var basis: Basis = .progress
    }

    public struct TodayPlan: Sendable {
        public let matters: [ResumeItem]
        public let reminders: [ResumeItem]
        public let commitments: [Commitment]
        public let missingReview: Date?
        private let day: LocalDay

        fileprivate init(matters: [ResumeItem], reminders: [ResumeItem], commitments: [Commitment], missingReview: Date?, day: LocalDay) {
            self.matters = matters
            self.reminders = reminders
            self.commitments = commitments
            self.missingReview = missingReview
            self.day = day
        }

        /// Store only a date-scoped digest. Legacy topic IDs can contain a readable title.
        public func selectionKey(for item: ResumeItem) -> String {
            CaptureUnderstandingEngine.digest("\(day.sortKey)|" + item.id)
        }

        public func focus(selection: String) -> ResumeItem? {
            if !selection.isEmpty, let selected = matters.first(where: { selectionKey(for: $0) == selection }) { return selected }
            return matters.first
        }
    }

    public static func today(in state: RecallState, matters: [MatterFile], now: Date = .now, calendar: Calendar = .current) -> TodayPlan {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        let reminders = state.reminders.compactMap { reminder -> ResumeItem? in
            guard reminder.status.isAction,
                  let due = ReminderTimeline.effectiveDueAt(reminder) ?? reminder.plannedForDay?.date, due < end else { return nil }
            let detail: String
            if due < start { detail = RecallLocalization.both("已逾期", "Overdue") + " · " + due.formatted(date: .abbreviated, time: .omitted) }
            else if ReminderTimeline.effectiveDueAt(reminder) == nil { detail = RecallLocalization.both("今天", "Today") }
            else { detail = due.formatted(date: .omitted, time: .shortened) }
            return ResumeItem(id: "reminder-" + reminder.id.uuidString, kind: .dueReminder, title: reminder.title, detail: detail,
                              destination: .reminder(reminder.id), date: due)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        return TodayPlan(matters: openMatters(in: state, matters: matters, today: start, calendar: calendar),
                         reminders: reminders, commitments: commitments(in: state, now: now),
                         missingReview: missingReviewDay(in: state, today: start, calendar: calendar),
                         day: LocalDay(now, timeZone: calendar.timeZone))
    }

    /// Compact, flat brief retained for existing callers.
    public static func resume(in state: RecallState, matters: [MatterFile], now: Date = .now, calendar: Calendar = .current) -> [ResumeItem] {
        let plan = today(in: state, matters: matters, now: now, calendar: calendar)
        var items = plan.reminders
        if let missing = plan.missingReview {
            let label = dayLabel(missing, today: calendar.startOfDay(for: now), calendar: calendar)
            items.append(ResumeItem(id: "missing-review", kind: .missingReview,
                title: RecallLocalization.both("\(label)还没有回顾", "No review for \(label) yet"),
                detail: RecallLocalization.both("生成后，这里会列出那天没做完的事", "Generate it to see what was left open"),
                destination: .daily(UUID()), date: missing))
        }
        for var item in plan.matters.prefix(5) {
            let status = statusLabel(item.status)
            let first = firstClause(item.detail)
            item.detail = first.isEmpty ? status : status + " · " + first
            items.append(item)
        }
        for owed in plan.commitments.filter({ $0.direction == .owedToMe }).prefix(2) {
            items.append(ResumeItem(id: "owed-" + owed.id, kind: .waitingOnOthers, title: owed.title,
                detail: RecallLocalization.both("等待对方：", "Waiting on: ") + owed.counterpart, destination: .record(owed.sourceID), date: owed.date))
        }
        return items
    }

    /// Only attributed review items and next steps the user explicitly wrote can supply the text of a focus.
    static func openMatters(in state: RecallState, matters: [MatterFile], today: Date, calendar: Calendar) -> [ResumeItem] {
        let horizon = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let sources = Dictionary(uniqueKeysWithValues: usable(state).map { ($0.id, $0) })
        let registry = state.topicRegistry
        var files: [String: MatterFile] = [:]
        for file in matters {
            files[state.canonicalTopicID(file.id)] = file
            files["topic:" + DailyKnowledgeEngine.canonicalKey(file.title, aliases: state.topicAliases)] = file
            if let topic = registry.topic(forName: file.title) { files["topic:" + topic.id.uuidString] = file }
        }
        for group in state.topicGroups {
            guard let file = files[group.id] else { continue }
            for id in group.memberIDs { files[state.canonicalTopicID(id)] = file }
        }
        let completionIDs = Set(state.matterCorrections.filter(\.isTopicCompletion).compactMap { $0.topicID.map(state.canonicalTopicID) })
        func key(for topic: String?, id: UUID?, title: String) -> String {
            if let id, registry.topic(id: id) != nil { return "topic:" + id.uuidString }
            if let topic, !topic.isEmpty {
                if let registered = registry.topic(forName: topic) { return "topic:" + registered.id.uuidString }
                return "topic:" + DailyKnowledgeEngine.canonicalKey(topic, aliases: state.topicAliases)
            }
            return id.map { "topic:" + $0.uuidString } ?? "title:" + DailyKnowledgeEngine.topicKey(title)
        }
        struct Mention {
            let item: ResumeItem
            let eligible: Bool
            let highlight: Bool
            let reviewCreatedAt: Date
        }
        var latest: [String: Mention] = [:]
        for review in state.dailySummaries where !review.sourceCaptureIDs.isEmpty {
            let day = calendar.startOfDay(for: review.day)
            guard day >= horizon, day <= today else { continue }
            func add(title: String, detail: String, status: String, owned: Bool, kind: DailyItemKind?, topic: String?, topicID: UUID?,
                     evidence: [UUID], section: DailySummarySection?, highlight: Bool) {
                guard !evidence.isEmpty, evidence.allSatisfy({ sources[$0] != nil }) else { return }
                let topicKey = key(for: topic, id: topicID, title: title)
                let file = files[topicKey]
                let id = file?.id ?? topicKey
                let workStatus = DailyKnowledgeEngine.status(status)
                let lifecycle = topic.flatMap { registry.topic(forName: $0)?.manualLifecycle }
                let closed = file.map { $0.latest.status == .completed } ?? completionIDs.contains(topicKey)
                let eligible = owned && (kind == .matter || kind == .agreement) && workStatus.isOpenMatter
                    && !closed && lifecycle != .done && lifecycle != .archived
                let item = ResumeItem(id: "matter-" + id, kind: .openMatter, title: title, detail: detail,
                    destination: file.map { .topic($0.id) } ?? .daily(review.id), date: day,
                    topic: file?.title ?? topic, status: workStatus, basis: section?.canonical == .actions ? .action : .progress)
                if let previous = latest[id] {
                    if previous.item.date > day { return }
                    if previous.item.date == day {
                        // A review may describe both a completed milestone and its still-open follow-up.
                        if previous.eligible != eligible { if previous.eligible { return } }
                        else if previous.item.basis != item.basis { if previous.item.basis == .action { return } }
                        else if previous.highlight != highlight { if previous.highlight { return } }
                        else if previous.item.title <= title { return }
                    }
                }
                latest[id] = Mention(item: item, eligible: eligible, highlight: highlight, reviewCreatedAt: review.createdAt)
            }
            for item in review.items {
                add(title: item.title, detail: item.detail, status: item.knowledge?.status ?? "", owned: item.knowledge?.ownedByUser ?? false,
                    kind: item.knowledge?.kind, topic: item.knowledge?.topic, topicID: item.knowledge?.topicID,
                    evidence: item.evidenceIDs, section: item.section, highlight: true)
            }
            for row in review.ledger {
                add(title: row.title, detail: row.detail, status: row.status, owned: row.ownedByUser, kind: row.kind,
                    topic: row.topic, topicID: nil, evidence: row.evidenceIDs, section: DailySummarySection(rawValue: row.section), highlight: false)
            }
        }

        var result = latest.compactMapValues { $0.eligible ? $0.item : nil }
        for file in matters where file.latest.status == .pending && file.latest.date >= horizon {
            let event = file.latest
            guard calendar.startOfDay(for: event.date) <= today,
                  event.evidenceIDs.count == 1, let sourceID = event.evidenceIDs.first, let source = sources[sourceID],
                  source.textOrigin == .userInput, let note = source.manualMatter, note.nextStepTopicID != nil, note.isValid,
                  event.nextAction == note.detail,
                  TopicRegistry.lifecycle(for: file, topic: registry.topic(forName: file.title), now: today, calendar: calendar) == .active else { continue }
            if let mention = latest[file.id], !mention.eligible,
               mention.item.date > calendar.startOfDay(for: event.date)
                || (mention.item.date == calendar.startOfDay(for: event.date) && mention.reviewCreatedAt >= source.createdAt) { continue }
            result[file.id] = ResumeItem(id: "matter-" + file.id, kind: .openMatter, title: note.detail, detail: "",
                destination: .topic(file.id), date: event.date, topic: file.title, status: .pending, basis: .handwritten)
        }
        return result.values.sorted {
            if $0.basis != $1.basis { return $0.basis.rawValue < $1.basis.rawValue }
            if $0.date != $1.date { return $0.date > $1.date }
            if ($0.status == .blocked) != ($1.status == .blocked) { return $0.status != .blocked }
            return $0.id < $1.id
        }
    }

    /// The most recent day before today with records, when it has no review. Only the last 3 days count.
    static func missingReviewDay(in state: RecallState, today: Date, calendar: Calendar) -> Date? {
        guard let last = usable(state).filter({ $0.createdAt < today }).max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        let day = calendar.startOfDay(for: last.createdAt)
        guard day >= (calendar.date(byAdding: .day, value: -3, to: today) ?? today), state.dailyReview(on: day, calendar: calendar) == nil else { return nil }
        return day
    }

    private static func statusLabel(_ status: WorkEpisodeStatus?) -> String {
        switch status {
        case .blocked: RecallLocalization.both("受阻", "Blocked")
        case .pending: RecallLocalization.both("待处理", "To do")
        default: RecallLocalization.both("进行中", "In progress")
        }
    }

    private static func dayLabel(_ day: Date, today: Date, calendar: Calendar) -> String {
        let offset = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if offset == 1 { return RecallLocalization.both("昨天", "yesterday") }
        if offset == 2 { return RecallLocalization.both("前天", "the day before yesterday") }
        return day.formatted(.dateTime.month().day())
    }

    /// The first sentence of a review detail, cut on a clause boundary.
    static func firstClause(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = trimmed.split(whereSeparator: { "。；;\n".contains($0) }).first.map(String.init) ?? trimmed
        return truncatedAtClause(sentence, limit: 48)
    }

    /// Cut on a clause boundary so a long summary never ends mid-phrase.
    private static func truncatedAtClause(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let cutoff = head.lastIndex(where: { "，。；！？、,.;!? ".contains($0) }), cutoff > head.startIndex {
            return String(head[head.startIndex..<cutoff]) + "…"
        }
        return String(text.prefix(limit - 1)) + "…"
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
