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

    public struct MissingReviewPrompt: Sendable, Equatable {
        public var day: Date
        public var recordCount: Int
        public var dayLabel: String
        public var title: String

        public init(day: Date, recordCount: Int, dayLabel: String, title: String) {
            self.day = day
            self.recordCount = recordCount
            self.dayLabel = dayLabel
            self.title = title
        }

        public var asResumeItem: ResumeItem {
            let hint = RecallLocalization.both("生成后，这里会列出那天没做完的事", "Generate it to see what was left open")
            return ResumeItem(
                id: "missing-review",
                kind: .missingReview,
                title: title,
                detail: hint,
                destination: .daily(UUID()),
                date: day,
                summaryText: hint,
                fullDetail: hint,
                priorityRank: 99
            )
        }
    }

    public struct TodayBrief: Sendable, Equatable {
        public var actionItems: [ResumeItem]
        public var totalOpenMatterCount: Int
        public var waitingItems: [ResumeItem]
        public var missingReview: MissingReviewPrompt?

        public init(
            actionItems: [ResumeItem],
            totalOpenMatterCount: Int,
            waitingItems: [ResumeItem],
            missingReview: MissingReviewPrompt?
        ) {
            self.actionItems = actionItems
            self.totalOpenMatterCount = totalOpenMatterCount
            self.waitingItems = waitingItems
            self.missingReview = missingReview
        }
    }

    public struct ResumeItem: Identifiable, Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case openMatter, missingReview, dueReminder, waitingOnOthers }
        public var id: String
        public var kind: Kind
        public var title: String
        public var detail: String
        public var destination: MemorySearchDestination
        /// For `missingReview`, the day to generate; otherwise the item's date.
        public var date: Date
        public var status: WorkEpisodeStatus?
        public var summaryText: String
        /// Full untruncated context for the top focus card.
        public var fullDetail: String
        /// Explicit next step left by the user or recorded as an open action, never fabricated.
        public var nextAction: String?
        /// True when the user explicitly left a next-step note ("给下次的自己留一句").
        public var hasUserNextStep: Bool
        public var topicID: String?
        public var topicTitle: String?
        public var reminderID: UUID?
        public var evidenceIDs: [UUID]
        /// Locally saved http/https URL on an evidence record (only present when `recordPageAddress` saved one).
        public var savedPageURL: String?
        /// Concrete reference code/hash in the saved text (e.g. `PR #42`) for quick copy when no URL exists.
        public var referenceToken: String?
        /// Action urgency tier: 0 = user next step, 1 = due reminder, 2 = blocked, 3 = pending, 4 = in progress.
        public var priorityRank: Int

        public init(
            id: String,
            kind: Kind,
            title: String,
            detail: String,
            destination: MemorySearchDestination,
            date: Date,
            status: WorkEpisodeStatus? = nil,
            summaryText: String? = nil,
            fullDetail: String? = nil,
            nextAction: String? = nil,
            hasUserNextStep: Bool = false,
            topicID: String? = nil,
            topicTitle: String? = nil,
            reminderID: UUID? = nil,
            evidenceIDs: [UUID] = [],
            savedPageURL: String? = nil,
            referenceToken: String? = nil,
            priorityRank: Int = 4
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.destination = destination
            self.date = date
            self.status = status
            self.summaryText = summaryText ?? detail
            self.fullDetail = fullDetail ?? summaryText ?? detail
            self.nextAction = nextAction
            self.hasUserNextStep = hasUserNextStep
            self.topicID = topicID
            self.topicTitle = topicTitle
            self.reminderID = reminderID
            self.evidenceIDs = evidenceIDs
            self.savedPageURL = savedPageURL
            self.referenceToken = referenceToken
            self.priorityRank = priorityRank
        }
    }

    /// Structured projection for "Today · Pick up where you stopped":
    /// 1. Strict action priority ordering: user's explicit next step > overdue/due today reminders > blocked > pending > in progress.
    /// 2. Separates "waiting on others / external result" into `waitingItems`.
    /// 3. Sinks "missing daily review" to `missingReview` at the bottom as a maintenance prompt.
    public static func todayBrief(
        in state: RecallState,
        matters: [MatterFile],
        now: Date = .now,
        calendar: Calendar = .current,
        matterLimit: Int = 5
    ) -> TodayBrief {
        let today = calendar.startOfDay(for: now)
        let usableRecords = usable(state)
        let usableByID = Dictionary(uniqueKeysWithValues: usableRecords.map { ($0.id, $0) })

        var dueReminders: [ResumeItem] = []
        for reminder in state.reminders where reminder.status.isAction {
            guard let due = ReminderTimeline.effectiveDueAt(reminder) ?? reminder.plannedForDay?.date,
                  due < (calendar.date(byAdding: .day, value: 1, to: today) ?? now) else { continue }
            let isOverdue = due < now
            let dueLabel = isOverdue ? RecallLocalization.both("已到期", "Overdue") : due.formatted(date: .omitted, time: .shortened)
            let trimmedDetail = reminder.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortSummary = trimmedDetail.isEmpty ? dueLabel : dueLabel + " · " + firstClause(trimmedDetail)
            let full = trimmedDetail.isEmpty ? dueLabel : trimmedDetail
            dueReminders.append(ResumeItem(
                id: "reminder-" + reminder.id.uuidString,
                kind: .dueReminder,
                title: reminder.title,
                detail: dueLabel,
                destination: .reminder(reminder.id),
                date: due,
                summaryText: shortSummary,
                fullDetail: full,
                reminderID: reminder.id,
                evidenceIDs: reminder.sourceCaptureIDs,
                savedPageURL: firstSavedWebURL(in: reminder.sourceCaptureIDs, records: usableByID),
                referenceToken: extractReferenceToken(from: reminder.title + " " + trimmedDetail),
                priorityRank: 1
            ))
        }
        dueReminders.sort { lhs, rhs in
            let leftOverdue = lhs.date < now
            let rightOverdue = rhs.date < now
            if leftOverdue != rightOverdue { return leftOverdue && !rightOverdue }
            return lhs.date < rhs.date
        }

        let computed = computeMatters(in: state, matters: matters, usableRecords: usableRecords, usableByID: usableByID, today: today, calendar: calendar)
        let limitedOpenMatters = Array(computed.open.prefix(max(0, matterLimit)))

        var actionItems = dueReminders + limitedOpenMatters
        actionItems.sort { lhs, rhs in
            if lhs.priorityRank != rhs.priorityRank {
                return lhs.priorityRank < rhs.priorityRank
            }
            if lhs.kind == .dueReminder, rhs.kind == .dueReminder {
                let leftOverdue = lhs.date < now
                let rightOverdue = rhs.date < now
                if leftOverdue != rightOverdue { return leftOverdue && !rightOverdue }
                return lhs.date < rhs.date
            }
            return lhs.date > rhs.date
        }

        var waitingItems = computed.waiting
        var seenWaitingTitles = Set(waitingItems.map { DailyKnowledgeEngine.topicKey($0.title) })
        for owed in commitments(in: state, now: now).filter({ $0.direction == .owedToMe }).prefix(4) {
            guard seenWaitingTitles.insert(DailyKnowledgeEngine.topicKey(owed.title)).inserted else { continue }
            let confirmedText = lastConfirmedDayLabel(owed.date, today: today, calendar: calendar)
            let text = RecallLocalization.both("\(confirmedText)最后确认：等待 ", "Last confirmed \(confirmedText): waiting on ") + owed.counterpart
            let summary = owed.counterpart + (owed.deadline.map { " · " + $0 } ?? "")
            waitingItems.append(ResumeItem(
                id: "owed-" + owed.id,
                kind: .waitingOnOthers,
                title: owed.title,
                detail: text,
                destination: .record(owed.sourceID),
                date: owed.date,
                summaryText: summary,
                fullDetail: text + (owed.deadline.map { "（\($0)）" } ?? ""),
                evidenceIDs: [owed.sourceID],
                savedPageURL: firstSavedWebURL(in: [owed.sourceID], records: usableByID),
                referenceToken: extractReferenceToken(from: owed.title),
                priorityRank: 10
            ))
        }

        let missingPrompt: MissingReviewPrompt? = missingReviewDay(in: state, today: today, calendar: calendar).map { missing in
            let count = usableRecords.filter { calendar.isDate($0.createdAt, inSameDayAs: missing) }.count
            let label = dayLabel(missing, today: today, calendar: calendar)
            let title = count > 0
                ? RecallLocalization.both("\(label)有 \(count) 条记录还没有生成回顾", "\(count) records from \(label) have no review yet")
                : RecallLocalization.both("\(label)还没有回顾", "No review for \(label) yet")
            return MissingReviewPrompt(day: missing, recordCount: count, dayLabel: label, title: title)
        }

        return TodayBrief(
            actionItems: actionItems,
            totalOpenMatterCount: computed.open.count,
            waitingItems: waitingItems,
            missingReview: missingPrompt
        )
    }

    /// "Pick up where you stopped": actionable reminders and open matters ordered by urgency first,
    /// with any missing-review maintenance prompt placed after actionable items.
    public static func resume(
        in state: RecallState,
        matters: [MatterFile],
        now: Date = .now,
        calendar: Calendar = .current,
        matterLimit: Int = 5
    ) -> [ResumeItem] {
        let brief = todayBrief(in: state, matters: matters, now: now, calendar: calendar, matterLimit: matterLimit)
        if let missing = brief.missingReview {
            return brief.actionItems + [missing.asResumeItem]
        }
        return brief.actionItems
    }

    public static func openMatterCount(in state: RecallState, matters: [MatterFile], now: Date = .now, calendar: Calendar = .current) -> Int {
        let usableRecords = usable(state)
        let usableByID = Dictionary(uniqueKeysWithValues: usableRecords.map { ($0.id, $0) })
        return computeMatters(
            in: state,
            matters: matters,
            usableRecords: usableRecords,
            usableByID: usableByID,
            today: calendar.startOfDay(for: now),
            calendar: calendar
        ).open.count
    }

    /// The user's own matters that the most recent mention in the last 7 days of reviews or manual notes leaves open.
    /// A later review or manual note that marks the same topic done, or the user marking the topic complete/dormant, closes it.
    static func openMatters(in state: RecallState, matters: [MatterFile], today: Date, calendar: Calendar) -> [ResumeItem] {
        let usableRecords = usable(state)
        let usableByID = Dictionary(uniqueKeysWithValues: usableRecords.map { ($0.id, $0) })
        return computeMatters(
            in: state,
            matters: matters,
            usableRecords: usableRecords,
            usableByID: usableByID,
            today: today,
            calendar: calendar
        ).open
    }

    private static func computeMatters(
        in state: RecallState,
        matters: [MatterFile],
        usableRecords: [CaptureRecord],
        usableByID: [UUID: CaptureRecord],
        today: Date,
        calendar: Calendar
    ) -> (open: [ResumeItem], waiting: [ResumeItem]) {
        let horizon = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        struct Mention {
            var key: String
            var title: String
            var detail: String
            var status: String
            var owned: Bool
            var open: Bool
            var waiting: Bool
            var day: Date
            var recordedAt: Date
            var review: UUID?
            var topic: String?
            var evidence: [UUID]
            var isHighlight: Bool
            var isManualNote: Bool
            var explicitNextAction: String?
            var userLeftNextStep: Bool
        }
        var mentions: [Mention] = []
        let usableIDs = Set(usableRecords.map(\.id))
        let registry = state.topicRegistry

        func canonicalKey(topicID: UUID?, topicName: String?, fallbackTitle: String) -> String {
            if let id = topicID, let registered = registry.topic(id: id) {
                return "topic:" + registered.id.uuidString
            }
            if let name = topicName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                if let registered = registry.topic(forName: name) {
                    return "topic:" + registered.id.uuidString
                }
                let aliased = DailyKnowledgeEngine.canonicalKey(name, aliases: state.topicAliases)
                return "topic:" + aliased
            }
            if let id = topicID {
                return "topic:" + id.uuidString
            }
            return "title:" + DailyKnowledgeEngine.topicKey(fallbackTitle)
        }

        for review in state.dailySummaries where calendar.startOfDay(for: review.day) >= horizon && calendar.startOfDay(for: review.day) <= today && !review.sourceCaptureIDs.isEmpty {
            let reviewDay = calendar.startOfDay(for: review.day)
            func add(
                title: String,
                detail: String,
                status: String,
                owned: Bool,
                kind: DailyItemKind?,
                section: DailySummarySection?,
                topic: String?,
                topicID: UUID?,
                evidence: [UUID],
                isHighlight: Bool
            ) {
                // Sources deleted or corrected away take their items with them.
                guard !evidence.isEmpty, Set(evidence).isSubset(of: usableIDs) else { return }
                // Filter out pure observations/insights that lack user follow-up ownership.
                if section?.canonical == .insights { return }
                let isMatter = kind == nil || kind == .matter || kind == .agreement
                let key = canonicalKey(topicID: topicID, topicName: topic, fallbackTitle: title)
                let isOpen = ["pending", "blocked", "inProgress", "progressed"].contains(status)
                let isWaiting = status == "waiting"
                let explicitNext: String? = if section?.canonical == .actions && isOpen {
                    title.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    ManualMatterNote.extractedNextAction(from: detail)
                }
                let earliestCaptureAt = evidence.compactMap { usableByID[$0]?.createdAt }.max() ?? review.createdAt
                mentions.append(Mention(
                    key: key,
                    title: title,
                    detail: detail,
                    status: status,
                    owned: owned && isMatter,
                    open: isOpen,
                    waiting: isWaiting,
                    day: reviewDay,
                    recordedAt: earliestCaptureAt,
                    review: review.id,
                    topic: topic,
                    evidence: evidence,
                    isHighlight: isHighlight,
                    isManualNote: false,
                    explicitNextAction: explicitNext,
                    userLeftNextStep: false
                ))
            }
            for item in review.items {
                add(
                    title: item.title,
                    detail: item.detail,
                    status: item.knowledge?.status ?? "unknown",
                    owned: item.knowledge?.ownedByUser ?? false,
                    kind: item.knowledge?.kind,
                    section: item.section,
                    topic: item.knowledge?.topic,
                    topicID: item.knowledge?.topicID,
                    evidence: item.evidenceIDs,
                    isHighlight: true
                )
            }
            for entry in review.ledger {
                add(
                    title: entry.title,
                    detail: entry.detail,
                    status: entry.status,
                    owned: entry.ownedByUser,
                    kind: entry.kind,
                    section: DailySummarySection(rawValue: entry.section),
                    topic: entry.topic,
                    topicID: nil,
                    evidence: entry.evidenceIDs,
                    isHighlight: false
                )
            }
        }

        // User-authored ManualMatterNotes ("记下进展" / "给下次的自己留一句") take effect immediately without
        // needing a model-generated Daily Review first, while raw unreviewed screen OCR stays excluded.
        // Notes already cited by a saved DailySummary are represented by that review to avoid duplicate topic keys.
        let reviewedCaptureIDs = Set(state.dailySummaries.flatMap(\.sourceCaptureIDs))
        let nonTopicCorrections = state.matterCorrections.filter { !$0.isTopicCompletion }
        for record in usableRecords where record.textOrigin == .userInput {
            guard let note = record.manualMatter, note.isValid else { continue }
            if reviewedCaptureIDs.contains(record.id), note.resolvedNextAction == nil { continue }
            let recordCorrections = nonTopicCorrections.filter { $0.evidenceIDs.contains(record.id) }
            let eventDate = recordCorrections.last(where: { $0.kind == .eventDate })?.eventAt ?? note.eventAt
            let eventDay = calendar.startOfDay(for: eventDate)
            guard eventDay >= horizon && eventDay <= today else { continue }
            let renamedTitle = recordCorrections.last(where: { $0.kind == .separate && !$0.text.isEmpty })?.text ?? note.title
            let isMarkedDone = recordCorrections.contains { $0.kind == .completed } || note.status == .completed
            let statusString: String = if isMarkedDone {
                "completed"
            } else {
                switch note.status {
                case .blocked: "blocked"
                case .pending: "pending"
                case .progressed: "progressed"
                case .completed: "completed"
                case .explored: "explored"
                }
            }
            let isOpen = ["pending", "blocked", "progressed"].contains(statusString)
            let userNext = isOpen ? note.resolvedNextAction : nil
            let key = canonicalKey(topicID: nil, topicName: renamedTitle, fallbackTitle: renamedTitle)
            let headline = userNext ?? firstClause(note.detail)
            mentions.append(Mention(
                key: key,
                title: headline.isEmpty ? renamedTitle : headline,
                detail: note.detail,
                status: statusString,
                owned: true,
                open: isOpen,
                waiting: false,
                day: eventDay,
                recordedAt: record.createdAt,
                review: nil,
                topic: renamedTitle,
                evidence: [record.id],
                isHighlight: true,
                isManualNote: true,
                explicitNextAction: userNext,
                userLeftNextStep: userNext != nil
            ))
        }

        // The newest mention of a topic decides whether it is still open; on the same day, a later manual note
        // or highlighted item wins over earlier/duplicate rows.
        var latest: [String: Mention] = [:]
        let orderedMentions = mentions.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.isManualNote != rhs.isManualNote { return !lhs.isManualNote && rhs.isManualNote }
            if lhs.isManualNote && rhs.isManualNote { return lhs.recordedAt < rhs.recordedAt }
            return !lhs.isHighlight && rhs.isHighlight
        }
        for var mention in orderedMentions {
            if let kept = latest[mention.key], kept.day == mention.day {
                if !mention.isManualNote {
                    if kept.isManualNote && kept.recordedAt >= mention.recordedAt { continue }
                    if kept.open && !mention.open { continue }
                    if kept.isHighlight && !mention.isHighlight && kept.open == mention.open { continue }
                }
                if mention.open, mention.explicitNextAction == nil, let keptNext = kept.explicitNextAction {
                    mention.explicitNextAction = keptNext
                    mention.userLeftNextStep = kept.userLeftNextStep
                }
            }
            latest[mention.key] = mention
        }

        // Index MatterFiles by canonical ID, normalized title, and registered aliases so renames/merges and completions always resolve.
        var matterLookup: [String: MatterFile] = [:]
        for file in matters {
            let canonicalID = state.canonicalTopicID(file.id)
            matterLookup[canonicalID] = matterLookup[canonicalID] ?? file
            matterLookup[file.id] = matterLookup[file.id] ?? file
            let titleKey = "topic:" + DailyKnowledgeEngine.topicKey(file.title)
            matterLookup[titleKey] = matterLookup[titleKey] ?? file
            if let registered = registry.topic(forName: file.title) {
                let regKey = "topic:" + registered.id.uuidString
                matterLookup[regKey] = matterLookup[regKey] ?? file
                for alias in registered.aliases {
                    let aliasKey = "topic:" + DailyKnowledgeEngine.topicKey(alias)
                    matterLookup[aliasKey] = matterLookup[aliasKey] ?? file
                }
            }
        }
        func resolveMatter(_ mention: Mention) -> MatterFile? {
            if let hit = matterLookup[mention.key] { return hit }
            if let name = mention.topic, let hit = matterLookup["topic:" + DailyKnowledgeEngine.topicKey(name)] { return hit }
            return matters.first { $0.title.caseInsensitiveCompare(mention.topic ?? "") == .orderedSame }
        }
        let completedTopicIDs = Set(state.matterCorrections.compactMap { $0.isTopicCompletion ? $0.topicID.map { state.canonicalTopicID($0) } : nil })
        func isClosed(_ mention: Mention, matched: MatterFile?) -> Bool {
            if let matched {
                if matched.latest.status == .completed { return true }
                if matched.needsStatusUpdate(at: today, calendar: calendar) { return true }
                if let reg = registry.resolvedTopic(for: matched),
                   let manual = reg.manualLifecycle,
                   [.done, .dormant, .archived].contains(manual) {
                    if manual == .dormant,
                       let lastAt = reg.lastEventAt,
                       (mention.open || mention.waiting),
                       mention.day > calendar.startOfDay(for: lastAt) {
                        return false
                    }
                    return true
                }
            }
            if completedTopicIDs.contains(state.canonicalTopicID(mention.key)) || completedTopicIDs.contains(mention.key) { return true }
            if let registered = registry.resolvedTopic(id: mention.key, fallbackTitle: mention.topic),
               let manual = registered.manualLifecycle,
               [.done, .dormant, .archived].contains(manual) {
                if manual == .dormant,
                   let lastAt = registered.lastEventAt,
                   (mention.open || mention.waiting),
                   mention.day > calendar.startOfDay(for: lastAt) {
                    return false
                }
                return true
            }
            return false
        }

        func urgencyRank(for mention: Mention, matched: MatterFile?) -> Int {
            let hasUserStep = mention.userLeftNextStep || hasOpenUserNextStep(in: matched, usableByID: usableByID)
            if hasUserStep { return 0 }
            switch mention.status {
            case "blocked": return 2
            case "pending": return 3
            default: return 4
            }
        }

        var seenOpenTitles = Set<String>()
        let openItems: [ResumeItem] = latest.values
            .filter { mention in
                guard mention.open, mention.owned else { return false }
                return !isClosed(mention, matched: resolveMatter(mention))
            }
            .sorted { lhs, rhs in
                let leftRank = urgencyRank(for: lhs, matched: resolveMatter(lhs))
                let rightRank = urgencyRank(for: rhs, matched: resolveMatter(rhs))
                if leftRank != rightRank { return leftRank < rightRank }
                if lhs.day != rhs.day { return lhs.day > rhs.day }
                return lhs.recordedAt > rhs.recordedAt
            }
            .compactMap { mention in
                let normalizedTitle = DailyKnowledgeEngine.topicKey(mention.title)
                guard seenOpenTitles.insert(normalizedTitle).inserted else { return nil }
                let matched = resolveMatter(mention)
                let status = statusLabel(mention.status)
                let episodeStatus: WorkEpisodeStatus = switch mention.status {
                case "blocked": .blocked
                case "pending": .pending
                default: .progressed
                }
                let cleanDetail = strippedDuplicatePrefix(detail: mention.detail, headline: mention.title, topic: mention.topic)
                let first = firstClause(cleanDetail.isEmpty ? mention.detail : cleanDetail)
                let resolvedTopicName = matched?.title ?? registry.resolvedTopic(id: mention.key, fallbackTitle: mention.topic)?.title ?? mention.topic
                let resolvedTopicID = matched?.id ?? (mention.key.hasPrefix("topic:") ? mention.key : nil)
                let userNext = mention.userLeftNextStep || hasOpenUserNextStep(in: matched, usableByID: usableByID)
                let resolvedNextAction = mention.explicitNextAction
                    ?? (matched?.latest.status.isOpenMatter == true ? matched?.resumeNextAction?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
                let rank = urgencyRank(for: mention, matched: matched)
                let destination: MemorySearchDestination = if let matched {
                    .topic(matched.id)
                } else if let reviewID = mention.review {
                    .daily(reviewID)
                } else if let firstEvidence = mention.evidence.first {
                    .record(firstEvidence)
                } else {
                    .topic(mention.key)
                }
                return ResumeItem(
                    id: "matter-" + mention.key,
                    kind: .openMatter,
                    title: mention.title,
                    detail: first.isEmpty ? status : status + " · " + first,
                    destination: destination,
                    date: mention.day,
                    status: episodeStatus,
                    summaryText: first,
                    fullDetail: cleanDetail.isEmpty ? mention.detail : cleanDetail,
                    nextAction: resolvedNextAction?.isEmpty == false ? resolvedNextAction : nil,
                    hasUserNextStep: userNext,
                    topicID: resolvedTopicID,
                    topicTitle: resolvedTopicName?.trimmingCharacters(in: .whitespacesAndNewlines),
                    evidenceIDs: mention.evidence,
                    savedPageURL: firstSavedWebURL(in: mention.evidence, records: usableByID),
                    referenceToken: extractReferenceToken(from: mention.title + " " + mention.detail),
                    priorityRank: rank
                )
            }

        let waitingItems: [ResumeItem] = latest.values
            .filter { mention in
                guard mention.waiting, mention.owned else { return false }
                return !isClosed(mention, matched: resolveMatter(mention))
            }
            .sorted { $0.day > $1.day }
            .map { mention in
                let matched = resolveMatter(mention)
                let confirmed = lastConfirmedDayLabel(mention.day, today: today, calendar: calendar)
                let cleanDetail = strippedDuplicatePrefix(detail: mention.detail, headline: mention.title, topic: mention.topic)
                let summary = firstClause(cleanDetail.isEmpty ? mention.detail : cleanDetail)
                let resolvedTopicName = matched?.title ?? registry.resolvedTopic(id: mention.key, fallbackTitle: mention.topic)?.title ?? mention.topic
                let resolvedTopicID = matched?.id ?? (mention.key.hasPrefix("topic:") ? mention.key : nil)
                return ResumeItem(
                    id: "waiting-" + mention.key,
                    kind: .waitingOnOthers,
                    title: resolvedTopicName ?? mention.title,
                    detail: RecallLocalization.both("\(confirmed)最后确认：", "Last confirmed \(confirmed): ") + (summary.isEmpty ? mention.title : summary),
                    destination: matched.map { .topic($0.id) } ?? (mention.review.map { .daily($0) } ?? .topic(mention.key)),
                    date: mention.day,
                    summaryText: summary,
                    fullDetail: cleanDetail.isEmpty ? mention.detail : cleanDetail,
                    topicID: resolvedTopicID,
                    topicTitle: resolvedTopicName,
                    evidenceIDs: mention.evidence,
                    savedPageURL: firstSavedWebURL(in: mention.evidence, records: usableByID),
                    referenceToken: extractReferenceToken(from: mention.title + " " + mention.detail),
                    priorityRank: 10
                )
            }

        return (openItems, waitingItems)
    }

    private static func hasOpenUserNextStep(in file: MatterFile?, usableByID: [UUID: CaptureRecord]) -> Bool {
        guard let file, file.latest.status.isOpenMatter else { return false }
        for id in file.latest.evidenceIDs {
            if let note = usableByID[id]?.manualMatter, note.resolvedNextAction != nil {
                return true
            }
        }
        return false
    }

    private static func strippedDuplicatePrefix(detail: String, headline: String, topic: String?) -> String {
        var result = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in [headline, topic].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) where !candidate.isEmpty {
            for sep in ["：", ":"] where result.hasPrefix(candidate + sep) {
                let rest = String(result.dropFirst((candidate + sep).count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { result = rest }
            }
        }
        return result
    }

    static func firstSavedWebURL(in ids: [UUID], records: [UUID: CaptureRecord]) -> String? {
        for id in ids {
            guard let raw = records[id]?.pageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            return raw
        }
        return nil
    }

    static func extractReferenceToken(from text: String) -> String? {
        let patterns = [
            #"(?:PR|MR|Issue)\s*#\d+"#,
            #"[A-Z][A-Z0-9]{1,9}-\d{1,6}"#,
            #"#\d{2,6}"#
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range])
            }
        }
        return nil
    }

    private static func lastConfirmedDayLabel(_ date: Date, today: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if offset <= 0 { return RecallLocalization.both("今天", "today") }
        if offset == 1 { return RecallLocalization.both("昨天", "yesterday") }
        return day.formatted(.dateTime.month().day())
    }

    /// The most recent day before today with records, when it has no review. Only the last 3 days count.
    static func missingReviewDay(in state: RecallState, today: Date, calendar: Calendar) -> Date? {
        guard let last = usable(state).filter({ $0.createdAt < today }).max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        let day = calendar.startOfDay(for: last.createdAt)
        guard day >= (calendar.date(byAdding: .day, value: -3, to: today) ?? today), state.dailyReview(on: day, calendar: calendar) == nil else { return nil }
        return day
    }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "blocked": RecallLocalization.both("卡住了", "Blocked")
        case "pending": RecallLocalization.both("还没做", "To do")
        default: RecallLocalization.both("推进中", "In progress")
        }
    }

    private static func dayLabel(_ day: Date, today: Date, calendar: Calendar) -> String {
        let offset = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if offset == 1 { return RecallLocalization.both("昨天", "yesterday") }
        if offset == 2 { return RecallLocalization.both("前天", "the day before yesterday") }
        return day.formatted(.dateTime.month().day())
    }

    /// The first sentence of a review detail, cut on a clause boundary.
    public static func firstClause(_ text: String) -> String {
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
