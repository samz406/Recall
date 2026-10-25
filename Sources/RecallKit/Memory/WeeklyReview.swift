import Foundation
import CryptoKit

public enum ReviewCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case unclassified, work, personal, learning
    public var id: String { rawValue }
    public var title: String {
        switch self { case .unclassified: "未分类"; case .work: "工作"; case .personal: "生活"; case .learning: "学习" }
    }
}

public enum ReviewTemplateKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case personal, work, project, learning
    public var id: String { rawValue }
    public var title: String {
        switch self { case .personal: "我的一周"; case .work: "工作周报"; case .project: "项目与交付"; case .learning: "学习回顾" }
    }
    public var subtitle: String {
        switch self {
        case .personal: "工作与生活，留下值得记住的变化"
        case .work: "整理成果、问题与已明确的安排"
        case .project: "围绕项目，回看交付和后续约定"
        case .learning: "区分学过的内容与实际练习成果"
        }
    }
    public var symbol: String {
        switch self { case .personal: "leaf"; case .work: "briefcase"; case .project: "square.stack.3d.up"; case .learning: "book" }
    }
    public var requiresWorkScope: Bool { self == .work || self == .project }
    public func includes(category: ReviewCategory, topicID: String, scope: ReviewScope) -> Bool {
        if scope.useSelectedTopics && !scope.topicIDs.contains(topicID) { return false }
        if requiresWorkScope {
            return category != .personal && category != .learning
                && (category == .work || (scope.useSelectedTopics && scope.topicIDs.contains(topicID)))
        }
        return self != .learning || category == .learning || (scope.useSelectedTopics && scope.topicIDs.contains(topicID))
    }
}

public enum ReviewSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case progress, open, plans, notes
    public var id: String { rawValue }
    public var symbol: String {
        switch self { case .progress: "checkmark.seal"; case .open: "flag"; case .plans: "arrow.up.right"; case .notes: "bookmark" }
    }
}

public enum ReviewLength: String, Codable, CaseIterable, Identifiable, Sendable {
    case brief, standard, detailed
    public var id: String { rawValue }
    public var title: String { switch self { case .brief: "简洁"; case .standard: "适中"; case .detailed: "详细" } }
    public var excerptLimit: Int { switch self { case .brief: 1; case .standard: 3; case .detailed: Int.max } }
}

public enum ReviewTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case natural, formal
    public var id: String { rawValue }
    public var title: String { self == .natural ? "自然" : "正式" }
}

/// A report snapshots its template. Changing a saved format never rewrites history.
public struct ReviewTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ReviewTemplateKind
    public var name: String
    public var sections: [ReviewSection]
    public var headings: [String: String]
    public var length: ReviewLength
    public var tone: ReviewTone
    public var version: Int
    public init(kind: ReviewTemplateKind, id: String? = nil) {
        self.id = id ?? kind.rawValue; self.kind = kind; name = kind.title
        sections = ReviewSection.allCases; headings = [:]; length = .standard
        tone = kind.requiresWorkScope ? .formal : .natural; version = 1
    }
    public static var builtIns: [ReviewTemplate] { ReviewTemplateKind.allCases.map { ReviewTemplate(kind: $0) } }
    public func heading(_ section: ReviewSection) -> String {
        if let custom = headings[section.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        switch (kind, section) {
        case (.work, .progress): return "本周成果与进展"
        case (.project, .progress): return "项目进展与交付"
        case (.learning, .progress): return "练习与实际产出"
        case (_, .progress): return "这一周发生的变化"
        case (.work, .open): return "待解决问题与协助"
        case (.learning, .open): return "还没有弄清的问题"
        case (_, .open): return "尚未解决的事情"
        case (.work, .plans): return "后续已明确的安排"
        case (.project, .plans): return "后续约定"
        case (.learning, .plans): return "接着学习的内容"
        case (_, .plans): return "还想接续的事情"
        case (.learning, .notes): return "学习与阅读记录"
        case (.project, .notes): return "项目记录与反馈"
        case (.work, .notes): return "补充记录"
        case (_, .notes): return "值得记住的经历"
        }
    }
    public var isValid: Bool {
        (1...40).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count)
            && sections.count == ReviewSection.allCases.count
            && Set(sections).count == ReviewSection.allCases.count
            && headings.values.allSatisfy { $0.count <= 40 }
    }
}

public enum ReviewPeriodKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case currentWeek, previousWeek, recentSeven, currentMonth, previousMonth, custom
    public var id: String { rawValue }
    public var title: String {
        switch self { case .currentWeek: "本周截至现在"; case .previousWeek: "上一个完整周"; case .recentSeven: "最近七天"; case .currentMonth: "本月截至现在"; case .previousMonth: "上一个完整月"; case .custom: "自选日期" }
    }
}

public struct ReviewPeriod: Codable, Equatable, Sendable {
    public var start: Date
    /// Half-open boundary: a record at Monday 00:00 belongs only to the next week.
    public var end: Date
    public var timeZoneIdentifier: String
    public init(start: Date, end: Date, timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.start = start; self.end = end; self.timeZoneIdentifier = timeZoneIdentifier
    }
    public var isValid: Bool {
        guard TimeZone(identifier: timeZoneIdentifier) != nil,
              let limit = calendar.date(byAdding: .day, value: 31, to: start) else { return false }
        return start < end && end <= limit
    }
    public func contains(_ date: Date) -> Bool { date >= start && date < end }
    public var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        value.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current; return value
    }
    public var label: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy.MM.dd HH:mm"
        return formatter.string(from: start) + " — " + formatter.string(from: end)
    }
    public static func make(_ kind: ReviewPeriodKind, at now: Date = .now, calendar input: Calendar = .current) -> ReviewPeriod {
        var calendar = input; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        let day = calendar.startOfDay(for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? day
        let start: Date
        let end: Date
        switch kind {
        case .previousWeek:
            start = calendar.date(byAdding: .day, value: -7, to: week) ?? week; end = week
        case .recentSeven:
            start = calendar.date(byAdding: .day, value: -6, to: day) ?? day; end = now
        case .currentMonth: start = calendar.dateInterval(of: .month, for: now)?.start ?? day; end = now
        case .previousMonth:
            let month = calendar.dateInterval(of: .month, for: now)?.start ?? day
            start = calendar.date(byAdding: .month, value: -1, to: month) ?? month; end = month
        case .currentWeek, .custom: start = week; end = now
        }
        return ReviewPeriod(start: start, end: end, timeZoneIdentifier: calendar.timeZone.identifier)
    }
}

public struct ReviewScope: Codable, Equatable, Sendable {
    /// Empty means all eligible topics, never all personal content for a work template.
    public var topicIDs: Set<String>
    public var useSelectedTopics: Bool
    public init(topicIDs: Set<String> = [], useSelectedTopics: Bool = false) {
        self.topicIDs = topicIDs; self.useSelectedTopics = useSelectedTopics || !topicIDs.isEmpty
    }
}

public struct ReviewExcerpt: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var status: WorkEpisodeStatus
    public var sourceIDs: [UUID]
    public var eventTimeKnown: Bool?
    public init(id: UUID, date: Date, text: String, status: WorkEpisodeStatus, sourceIDs: [UUID], eventTimeKnown: Bool? = nil) {
        self.id = id; self.date = date; self.text = text; self.status = status; self.sourceIDs = sourceIDs; self.eventTimeKnown = eventTimeKnown
    }
}

public struct ReviewNarrative: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var evidenceIDs: [UUID]
    public init(title: String, summary: String, evidenceIDs: [UUID]) {
        self.title = title; self.summary = summary; self.evidenceIDs = evidenceIDs
    }
}

public struct ReviewItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var category: ReviewCategory
    public var section: ReviewSection
    public var previous: ReviewExcerpt?
    public var excerpts: [ReviewExcerpt]
    public var featuredIDs: [UUID]
    public var nextAction: String?
    public var nextActionSourceIDs: [UUID]
    public var narrative: ReviewNarrative? = nil
    public var memberTopicIDs: [String]? = nil
    public var consolidatedRequiredIDs: [UUID]? = nil
    public var locallyGrouped: Bool? = nil
    public init(id: String, title: String, category: ReviewCategory, section: ReviewSection, previous: ReviewExcerpt?,
                excerpts: [ReviewExcerpt], featuredIDs: [UUID], nextAction: String?, nextActionSourceIDs: [UUID],
                narrative: ReviewNarrative? = nil, memberTopicIDs: [String]? = nil,
                consolidatedRequiredIDs: [UUID]? = nil, locallyGrouped: Bool? = nil) {
        self.id = id; self.title = title; self.category = category; self.section = section; self.previous = previous
        self.excerpts = excerpts; self.featuredIDs = featuredIDs; self.nextAction = nextAction; self.nextActionSourceIDs = nextActionSourceIDs
        self.narrative = narrative; self.memberTopicIDs = memberTopicIDs; self.consolidatedRequiredIDs = consolidatedRequiredIDs; self.locallyGrouped = locallyGrouped
    }
    public var displayTitle: String { narrative?.title ?? title }
    public var sourceIDs: [UUID] { Array(Set(excerpts.flatMap(\.sourceIDs) + (previous?.sourceIDs ?? []) + nextActionSourceIDs)).sorted { $0.uuidString < $1.uuidString } }
    public var requiredExcerptIDs: [UUID] {
        if let consolidatedRequiredIDs { return consolidatedRequiredIDs }
        var ids = excerpts.last.map { [$0.id] } ?? []
        if let outcome = excerpts.last(where: { $0.status == .completed }), !ids.contains(outcome.id) { ids.append(outcome.id) }
        return ids
    }
    public func featured(for length: ReviewLength) -> [ReviewExcerpt] {
        if length == .detailed { return excerpts }
        var ids = requiredExcerptIDs
        let limit = max(length.excerptLimit, ids.count)
        for id in featuredIDs + excerpts.reversed().map(\.id) where ids.count < limit {
            if !ids.contains(id) { ids.append(id) }
        }
        return excerpts.filter { ids.contains($0.id) }
    }
    /// Importance is based on the evidence, never a hash or source application name.
    public var importance: Int {
        if section == .open { return 4 }
        if excerpts.contains(where: { $0.status == .completed }) { return 3 }
        if section == .progress { return 2 }
        return section == .plans ? 1 : 0
    }

}

public struct WeeklyReport: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var createdAt: Date
    public var updatedAt: Date
    public var period: ReviewPeriod
    public var template: ReviewTemplate
    public var scope: ReviewScope
    public var items: [ReviewItem]
    public var sourceVersions: [UUID: String]
    public var editedMarkdown: String?
    public var invalidatedAt: Date?
    public var modelAssisted: Bool = false
    public var topicGrouping: [MemoryTopicGroup]? = nil
    /// Selected reading topics; all candidates/evidence remain in items. Nil denotes a legacy report.
    public var digestTopicIDs: [String]? = nil
    public var refinementPending: Bool = false
    public var scheduleID: UUID?
    public var scheduledFor: Date?
    public var refinementAttempts: Int? = nil
    public var refinementRetryAfter: Date? = nil
    public var refinementDeadline: Date? = nil

    public func canRefine(at now: Date) -> Bool {
        isReadable && editedMarkdown == nil && refinementPending && (refinementAttempts ?? 0) < 3
            && now < (refinementDeadline ?? createdAt.addingTimeInterval(86_400))
            && now >= (refinementRetryAfter ?? createdAt.addingTimeInterval(300))
    }
    public mutating func recordRefinementAttempt(at now: Date) {
        let count = (refinementAttempts ?? 0) + 1
        refinementAttempts = count
        refinementDeadline = refinementDeadline ?? createdAt.addingTimeInterval(86_400)
        refinementRetryAfter = now.addingTimeInterval(min(3_600, 300 * pow(2, Double(count - 1))))
    }
    public var sourceIDs: Set<UUID> { Set(sourceVersions.keys) }
    public var isReadable: Bool { invalidatedAt == nil }
    public var overview: String { isReadable ? digestOverview : "" }

    public var displayName: String {
        let long = (period.calendar.dateComponents([.day], from: period.start, to: period.end).day ?? 0) > 7 || period.calendar.dateInterval(of: .month, for: period.start)?.start == period.start
        guard long else { return template.name }
        if template.name == "我的一周" { return "我的回顾" }
        if template.name == "工作周报" { return "工作回顾" }
        return template.name
    }
    public func heading(_ section: ReviewSection) -> String {
        let heading = template.heading(section)
        guard template.headings[section.rawValue] == nil else { return heading }
        return ((period.calendar.dateComponents([.day], from: period.start, to: period.end).day ?? 0) > 7 || period.calendar.dateInterval(of: .month, for: period.start)?.start == period.start)
            ? heading.replacingOccurrences(of: "本周", with: "本期").replacingOccurrences(of: "这一周", with: "这段时间") : heading
    }
    public var markdown: String {
        guard isReadable else { return "原始记录已删除或更正，请重新生成这份回顾。" }
        if let editedMarkdown { return editedMarkdown }
        let digest = digestRows
        var lines = ["# \(displayName)", "", period.label, "", overview, ""]
        if digest.contains(where: \.isExtractive) {
            lines += ["部分小结来自明确归属的简短事实；完整过程保留在应用的整理依据中。", ""]
        }
        for section in template.sections {
            let rows = digest.filter { $0.item.section == section }
            guard !rows.isEmpty else { continue }
            lines += ["## " + heading(section), ""]
            for row in rows {
                lines += ["### " + row.title, ""]
                if !row.summary.isEmpty { lines += [row.summary, ""] }
                if let action = row.action { lines += ["已明确的后续安排：" + action, ""] }
            }
        }
        return lines.joined(separator: "\n")
    }
    /// Remove dependent text, including user edits, instead of merely concealing it in the UI.
    public mutating func invalidate(at date: Date = .now) {
        items = []; digestTopicIDs = nil; editedMarkdown = nil; sourceVersions = [:]; invalidatedAt = date; refinementPending = false
    }
}

public struct ReviewSchedule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var isEnabled: Bool = true
    public var weekday: Int = 1
    public var monthDay: Int? = nil
    public var hour: Int = 21
    public var minute: Int = 0
    public var timeZoneIdentifier: String = TimeZone.current.identifier
    public var periodKind: ReviewPeriodKind = .currentWeek
    public var template: ReviewTemplate
    public var scope: ReviewScope
    public var useModel: Bool = false
    public var notifyWhenReady: Bool = false
    public var nextRunAt: Date?
    public var retryAfter: Date?
    public var failureCount: Int = 0
    public var lastReportID: UUID?
    public init(template: ReviewTemplate, scope: ReviewScope = ReviewScope()) {
        self.template = template; self.scope = scope; name = template.name
    }
    public var isValid: Bool {
        template.isValid && (monthDay == nil || (1...28).contains(monthDay!)) && (1...7).contains(weekday) && (0...23).contains(hour) && (0...59).contains(minute)
            && TimeZone(identifier: timeZoneIdentifier) != nil && periodKind != .custom && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; return c
    }
    private var triggerComponents: DateComponents {
        if let monthDay { return DateComponents(day: monthDay, hour: hour, minute: minute) }
        return DateComponents(hour: hour, minute: minute, weekday: weekday)
    }
    public func nextTrigger(after date: Date) -> Date? {
        guard isValid else { return nil }
        return calendar.nextDate(after: date, matching: triggerComponents, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
    public func isDue(at now: Date) -> Bool {
        isEnabled && isValid && nextRunAt.map { $0 <= now } == true
            && (retryAfter == nil || retryAfter! <= now || (effectiveTrigger(at: now) ?? .distantPast) > (nextRunAt ?? .distantFuture))
    }
    public func period(at trigger: Date) -> ReviewPeriod {
        let selected = ReviewPeriod.make(periodKind, at: trigger, calendar: calendar)
        // Monday 00:00 has no current-week evidence yet: close the week that just ended.
        if selected.start == selected.end && periodKind == .currentMonth {
            return ReviewPeriod.make(.previousMonth, at: trigger, calendar: calendar)
        }
        return selected.start == selected.end && periodKind == .currentWeek
            ? ReviewPeriod.make(.previousWeek, at: trigger, calendar: calendar) : selected
    }
    public func effectiveTrigger(at now: Date) -> Date? {
        guard let due = nextRunAt, due <= now else { return nil }
        let latest = calendar.nextDate(after: now.addingTimeInterval(0.001),
            matching: triggerComponents,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .backward) ?? due
        return max(due, latest)
    }
}

/// New periods always take precedence. Refinement belongs to a saved report, never the schedule cursor.
public enum WeeklyReviewWork: Sendable {
    case generate(ReviewSchedule, Date)
    case refine(WeeklyReport, ReviewSchedule)
    public static func next(in state: RecallState, at now: Date, modelAvailable: Bool) -> WeeklyReviewWork? {
        if let plan = state.reviewSchedules.filter({ $0.isDue(at: now) })
            .sorted(by: { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }).first,
           let trigger = plan.effectiveTrigger(at: now) { return .generate(plan, trigger) }
        guard modelAvailable, state.privacy.cloudUseEnabled else { return nil }
        for report in state.weeklyReports where report.canRefine(at: now) {
            if let plan = state.reviewSchedules.first(where: {
                $0.id == report.scheduleID && $0.lastReportID == report.id && $0.isEnabled && $0.useModel
                    && $0.template == report.template && $0.scope == report.scope
            }) { return .refine(report, plan) }
        }
        return nil
    }
}

public enum WeeklyReviewError: Error, LocalizedError, Equatable {
    case noEvidence, invalidPeriod, invalidTemplate, changedSources, cancelled, noWorkScope
    public var errorDescription: String? {
        switch self {
        case .noEvidence: "这段时间没有符合范围的记录，可以换一个时间范围或补充记录。"
        case .invalidPeriod: "请选择不超过 31 天、且已发生的有效日期范围。"
        case .invalidTemplate: "请填写模板名称，并保留四类内容的栏目设置。"
        case .changedSources: "生成期间来源或设置发生了变化，请重新生成。"
        case .cancelled: "已取消本次生成。"
        case .noWorkScope: "所选日期内暂未识别出明确的工作内容，可以改用“我的一周”回顾全部内容。"
        }
    }
}

/// A week is built from primary evidence, never by concatenating seven generated summaries.
/// Optional composition is checked against the same ledger before replacing extractive text.
/// Ownership, dates, outcomes and explicit next actions remain source-bound.
public struct WeeklyReviewEngine: Sendable {
    public init() {}

    public func topics(in state: RecallState, matterFiles: [MatterFile]? = nil) -> [MatterFile] {
        var input = state
        input.captures.removeAll { state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }
        let safe = input.correctedForAnalysis()
        let allowed = Set(safe.captures.map(\.id))
        var files = (matterFiles ?? MatterMemoryEngine().files(in: input)).filter { Set($0.evidenceIDs).isSubset(of: allowed) }
        let originals = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0.createdAt) })
        // Reading/learning/life records do not need a work-progress verb. Still require
        // an explicit first-person action; a saved article or unknown chat role is not one.
        for record in safe.captures.sorted(by: { $0.createdAt < $1.createdAt }) where record.eventTemplate != .dailyReview {
            guard record.manualMatter == nil else { continue }
            for segment in RecordedText.segments(in: record) where segment.speaker == .user {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (8...420).contains(text.count), !text.contains("…"), !text.contains("..."),
                      !text.contains("http"), !text.contains("["),
                      let pair = personalSubject(text) else { continue }
                let key = "life:" + MatterEvidence.key(pair.0)
                var event = MatterEvent(id: MatterEvidence.eventID(source: record.id, topic: key, ordinal: segment.ordinal), title: pair.0, detail: text,
                    recordedAt: originals[record.id] ?? record.createdAt,
                    eventAt: state.matterCorrections.last(where: { $0.kind == .eventDate && $0.evidenceIDs.contains(record.id) })?.eventAt,
                    status: .explored, evidenceIDs: [record.id])
                event.sequence = segment.ordinal
                if let i = files.firstIndex(where: { $0.id == key }) {
                    if let j = files[i].events.firstIndex(where: {
                        MatterEvidence.key($0.detail) == MatterEvidence.key(text)
                            && $0.eventAt == event.eventAt
                    }) {
                        files[i].events[j].evidenceIDs = Array(Set(files[i].events[j].evidenceIDs + [record.id])).sorted { $0.uuidString < $1.uuidString }
                    } else { files[i].events.append(event) }
                } else { files.append(MatterFile(id: key, title: pair.0, events: [event])) }
            }
        }
        files += MemoryReferenceEngine().files(in: input, excluding: Set(files.flatMap(\.evidenceIDs)))
        for i in files.indices {
            files[i].events.sort { $0.date == $1.date ? $0.sequence < $1.sequence : $0.date < $1.date }
            // Scope/category settings must not retain a deleted person's name or original
            // topic sentence inside an identifier. Only opaque stable IDs leave the ledger.
            files[i].id = Self.topicID(for: files[i])
        }
        return files.sorted { $0.latest.date > $1.latest.date }
    }

    public static func topicID(for file: MatterFile) -> String {
        let prefix = file.id.hasPrefix("reference:") ? "reference:" : (file.id.hasPrefix("life:") ? "life:" : "topic:")
        return prefix + SHA256.hash(data: Data(file.id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func category(for file: MatterFile, in state: RecallState) -> ReviewCategory {
        ReviewCategoryIndex(state: state).category(for: file)
    }

    public func items(in state: RecallState, period: ReviewPeriod, template: ReviewTemplate, scope: ReviewScope) throws -> [ReviewItem] {
        guard period.isValid else { throw WeeklyReviewError.invalidPeriod }
        guard template.isValid else { throw WeeklyReviewError.invalidTemplate }
        let files = topics(in: state)
        let categories = ReviewCategoryIndex(state: state)
        if template.kind.requiresWorkScope && scope.topicIDs.isEmpty && !files.contains(where: { categories.category(for: $0) == .work }) {
            throw WeeklyReviewError.noWorkScope
        }
        var result: [ReviewItem] = []
        for file in files {
            let category = categories.category(for: file)
            guard template.kind.includes(category: category, topicID: file.id, scope: scope) else { continue }
            let changes = file.events.filter { period.contains($0.date) }
            guard let last = changes.last else { continue }
            let previous = file.events.last { $0.date < period.start }
            let actual = changes.filter { $0.status != .pending || $0.nextAction != nil }
            let separatedAction = last.status == .pending && last.nextAction == nil && !actual.isEmpty
            let visible = separatedAction ? actual : changes
            let current = visible.last ?? last
            let section: ReviewSection
            if current.status == .blocked { section = .open }
            else if current.status == .pending && current.nextAction == nil { section = .plans }
            else if current.status == .explored { section = .notes }
            else { section = .progress }
            let excerpts = visible.map { excerpt($0) }
            // Always retain the latest state. Preserve meaningful earlier outcomes rather
            // than blindly taking only the last three screenshots.
            var featured = [current.id]
            if let outcome = visible.last(where: { $0.status == .completed }), outcome.id != current.id { featured.append(outcome.id) }
            if let first = visible.first, !featured.contains(first.id) { featured.append(first.id) }
            let action = separatedAction ? last.detail : last.nextAction
            result.append(ReviewItem(id: file.id, title: clean(file.title), category: category, section: section,
                previous: previous.map(excerpt), excerpts: excerpts, featuredIDs: featured,
                nextAction: action.map(clean), nextActionSourceIDs: action == nil ? [] : last.evidenceIDs))
        }
        return result.sorted { lhs, rhs in
            let left = lhs.excerpts.last?.date ?? .distantPast, right = rhs.excerpts.last?.date ?? .distantPast
            return left == right ? lhs.id < rhs.id : left > right
        }
    }

    public func generate(in state: RecallState, period: ReviewPeriod, template: ReviewTemplate, scope: ReviewScope = ReviewScope(),
                         responder: (any LLMResponding)? = nil, now: Date = .now, onPhase: (@Sendable (String) async -> Void)? = nil) async throws -> WeeklyReport {
        guard period.end <= now.addingTimeInterval(1) else { throw WeeklyReviewError.invalidPeriod }
        await onPhase?("整理主题变化")
        var items = ReviewConsolidation.local(try items(in: state, period: period, template: template, scope: scope))
        guard !items.isEmpty else { throw WeeklyReviewError.noEvidence }
        try Task.checkCancellation()
        var assisted = false, pending = false
        var selectedIDs = ReviewDigest.candidates(items, period: period, limit: items.count)
            .filter { ReviewDigest.row($0, length: template.length) != nil }
            .prefix(template.length.itemLimit).map(\.id)
        if let responder, state.privacy.cloudUseEnabled {
            await onPhase?("撰写并核对回顾")
            let composed = try await WeeklyReviewComposition().compose(items: items, state: state, period: period,
                template: template, responder: responder)
            items = composed.items; assisted = composed.assisted; pending = composed.pending
            selectedIDs = composed.selectedIDs
        }
        await onPhase?("核验来源")
        var ids = Set(items.flatMap(\.sourceIDs))
        if state.privacy.cloudUseEnabled && responder != nil {
            let preferenceClaims = MemoryKnowledgeEngine().cloudEligibleClaims(in: state)
            let questionScope = template.kind.requiresWorkScope ? "工作周报" : (template.kind == .learning ? "学习回顾" : "个人回顾")
            let context = MemoryRetrievalEngine().preferenceContext(question: questionScope, claims: preferenceClaims, conversationID: nil, entities: Set(items.map(\.id))) ?? ""
            for claim in preferenceClaims where context.contains(claim.content) { ids.formUnion(claim.sourceIDs) }
        }
        let versions = Dictionary(uniqueKeysWithValues: ids.compactMap { id in Self.sourceVersion(id: id, state: state).map { (id, $0) } })
        var report = WeeklyReport(createdAt: now, updatedAt: now, period: period, template: template, scope: scope,
            items: items, sourceVersions: versions, modelAssisted: assisted, refinementPending: pending)
        report.topicGrouping = state.topicGroups
        report.digestTopicIDs = selectedIDs
        return report
    }

    public func refine(_ original: WeeklyReport, in state: RecallState, responder: any LLMResponding,
                       now: Date = .now) async throws -> WeeklyReport {
        guard original.isReadable, original.editedMarkdown == nil, state.privacy.cloudUseEnabled,
              Self.sourcesUnchanged(original, in: state) else { throw WeeklyReviewError.changedSources }
        let result = try await WeeklyReviewComposition().compose(items: original.items, state: state,
            period: original.period, template: original.template, responder: responder, selectedIDs: original.modelAssisted ? original.digestTopicIDs : nil)
        var report = original
        report.items = result.items; report.updatedAt = now
        report.digestTopicIDs = result.selectedIDs
        report.modelAssisted = report.digestRows.contains { !$0.isExtractive }
        report.refinementPending = result.pending
        return report
    }

    public static func sourceVersion(id: UUID, state: RecallState) -> String? {
        guard let source = state.captures.first(where: { $0.id == id }) else { return nil }
        return "memory2:" + MemoryKnowledgeEngine.version(of: source, corrections: state.matterCorrections)
    }

    private static func legacySourceVersion(id: UUID, state: RecallState) -> String? {
        guard let source = state.captures.first(where: { $0.id == id }) else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(source)) ?? Data()
        let corrections = (try? encoder.encode(state.matterCorrections.filter { $0.evidenceIDs.contains(id) })) ?? Data()
        return SHA256.hash(data: data + corrections).map { String(format: "%02x", $0) }.joined()
    }

    public static func sourcesUnchanged(_ report: WeeklyReport, in state: RecallState) -> Bool {
        (report.topicGrouping == nil || report.topicGrouping == state.topicGroups) && report.sourceVersions.allSatisfy { id, version in
            version.hasPrefix("memory2:") ? sourceVersion(id: id, state: state) == version : legacySourceVersion(id: id, state: state) == version
        } && MemoryKnowledgeEngine().sourcesUsable(report.sourceIDs, in: state)
    }

    private func excerpt(_ event: MatterEvent) -> ReviewExcerpt {
        ReviewExcerpt(id: event.id, date: event.date,
            text: (event.isReference ? "保存的内容（归属与实际状态未确认）：\n" : "") + clean(event.detail), status: event.resultStatus ?? event.status,
            sourceIDs: event.evidenceIDs, eventTimeKnown: event.eventAt != nil)
    }
    private func clean(_ text: String) -> String {
        DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(from: DailySummaryContentFormatter.removingCitationMarkers(from: text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func personalSubject(_ text: String) -> (String, ReviewCategory)? {
        let patterns: [(String, String, ReviewCategory)] = [
            (#"^(?:我|今天我|本周我|今天|昨天)(?:读完|阅读了|学习了|练习了)(.{3,65}?)(?=[，。；！]|$)"#, "学习", .learning),
            (#"^(?:我|今天我|本周我|今天|昨天)(?:陪|参加了|去了|跑完了|记录了)(.{3,65}?)(?=[，。；！]|$)"#, "经历", .personal)
        ]
        for (pattern, prefix, category) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return (prefix + " · " + text[range], category)
        }
        return nil
    }
}
