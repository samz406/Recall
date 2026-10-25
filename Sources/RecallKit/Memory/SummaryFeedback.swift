import Foundation
import CryptoKit

public enum SummaryFeedbackKind: String, Codable, Sendable { case daily, period }
public enum SummaryFeedbackState: String, Codable, Sendable {
    case queued, processing, waiting, retrying, applied, needsDetail, failed, withdrawn
    public var title: String {
        switch self {
        case .queued: "等待处理"; case .processing: "正在核对"; case .waiting: "等待模型连接"
        case .retrying: "稍后重试"; case .applied: "已调整"; case .needsDetail: "需要更多说明"
        case .failed: "未完成"; case .withdrawn: "已撤销"
        }
    }
    public var pending: Bool { [.queued, .processing, .waiting, .retrying].contains(self) }
}
public enum SummaryFeedbackDiagnosis: String, Codable, Sendable {
    case facts, attribution, omission, action, expression, relevance, unclear
}
/// Only bounded, declarative presentation policies can be learned. Never executable prompts.
public enum SummaryRuleKind: String, Codable, CaseIterable, Sendable {
    case concise, detailed, outcomesFirst, omitFileNames, noSpeculation, naturalTone, formalTone
    public var instruction: String {
        switch self {
        case .concise: "简明表达，只保留重要变化和必要背景，不重复标题。"
        case .detailed: "在模板允许的篇幅内补充结果、必要背景与未解决部分。"
        case .outcomesFirst: "先写具体结果和变化，再补充必要过程。"
        case .omitFileNames: "省略无关文件名、分支和提交编号，用具体业务结果表达。"
        case .noSpeculation: "只整理明确事实，省略关于心理、习惯和收益的推测。"
        case .naturalTone: "用自然、直接的中文表达，减少公文和算法术语。"
        case .formalTone: "用客观正式的中文表达，保留事实和状态边界。"
        }
    }
    var dimension: String {
        switch self { case .concise, .detailed: "length"; case .naturalTone, .formalTone: "tone"; default: rawValue }
    }
}
public struct SummaryLearnedRule: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: SummaryRuleKind
    public var quote: String
    public var reviewKind: SummaryFeedbackKind
    public var templateID: String?
    public var topicID: String?
    public var allReviews = false
    public init(kind: SummaryRuleKind, quote: String, reviewKind: SummaryFeedbackKind, templateID: String? = nil, topicID: String? = nil, allReviews: Bool = false) {
        self.kind = kind; self.quote = quote; self.reviewKind = reviewKind; self.templateID = templateID; self.topicID = topicID; self.allReviews = allReviews
    }
    private enum CodingKeys: String, CodingKey { case id, kind, quote, reviewKind, templateID, topicID, allReviews }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(SummaryRuleKind.self, forKey: .kind); quote = try c.decode(String.self, forKey: .quote)
        reviewKind = try c.decodeIfPresent(SummaryFeedbackKind.self, forKey: .reviewKind) ?? .daily
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID); topicID = try c.decodeIfPresent(String.self, forKey: .topicID)
        allReviews = try c.decodeIfPresent(Bool.self, forKey: .allReviews) ?? false
    }
}
public struct SummaryFeedbackItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var section: String
    public var sourceIDs: [UUID]
}
/// A receipt binds feedback to an immutable report revision, not to a recycled row number.
public struct SummaryFeedbackTarget: Codable, Equatable, Identifiable, Sendable {
    public var id: String { reportID.uuidString + (itemID ?? "") + revision }
    public var kind: SummaryFeedbackKind
    public var reportID: UUID
    public var itemID: String?
    public var revision: String
    public var title: String
    public var period: ReviewPeriod
    public var templateID: String?
    public var templateKind: ReviewTemplateKind?
    public var topicID: String?
    public var items: [SummaryFeedbackItem]
    public var editedText: String?
    public var length: ReviewLength?
    public static func daily(_ summary: DailySummary, item: DailySummaryItem? = nil) -> Self {
        let day = Calendar.current.startOfDay(for: summary.day)
        return Self(kind: .daily, reportID: summary.id, itemID: item?.id.uuidString,
            revision: SummaryFeedbackLearning.hash(summary), title: "每日回顾 · " + summary.day.formatted(date: .abbreviated, time: .omitted),
            period: ReviewPeriod(start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day),
            items: (item.map { [$0] } ?? summary.items).map {
                SummaryFeedbackItem(id: $0.id.uuidString, title: $0.title, detail: $0.detail,
                    section: $0.section.canonical.rawValue, sourceIDs: $0.evidenceIDs)
            })
    }
    public static func period(_ report: WeeklyReport, item: ReviewItem? = nil) -> Self {
        let rows = report.digestRows
        let values = item.map { [$0] } ?? rows.map(\.item)
        return Self(kind: .period, reportID: report.id, itemID: item?.id, revision: SummaryFeedbackLearning.hash(report),
            title: report.displayName + " · " + report.period.label, period: report.period, templateID: report.template.id,
            templateKind: report.template.kind, topicID: item?.id ?? (report.scope.useSelectedTopics && report.scope.topicIDs.count == 1 ? report.scope.topicIDs.first : nil),
            items: values.map { value in
                let row = rows.first { $0.id == value.id }
                return SummaryFeedbackItem(id: value.id, title: row?.title ?? value.displayTitle,
                    detail: row?.summary ?? value.narrative?.summary ?? "", section: value.section.rawValue, sourceIDs: value.sourceIDs)
            }, editedText: item == nil ? report.editedMarkdown : nil, length: report.template.length)
    }
}
public struct SummaryFeedbackChange: Codable, Equatable, Sendable {
    public var itemID: String?
    public var remove: Bool
    public var title: String
    public var detail: String
    public var section: String
    public var sourceIDs: [UUID]
}
public struct SummaryFactCorrection: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var originalQuote: String
    public var correctedQuote: String
    public var status: WorkEpisodeStatus?
}
public struct SummaryFeedbackSupplement: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var status: WorkEpisodeStatus
    public var quote: String
    /// Explicit date only; application verifies it against the user's words.
    public var occurredOn: String
}
public struct SummaryFeedbackResolution: Codable, Equatable, Sendable {
    public var supplement: SummaryFeedbackSupplement?
    public var diagnosis: SummaryFeedbackDiagnosis
    public var message: String
    public var changes: [SummaryFeedbackChange]
    public var corrections: [SummaryFactCorrection]
    public var rules: [SummaryLearnedRule]
}
public struct SummaryFeedback: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var target: SummaryFeedbackTarget
    public var text: String
    public var createdAt = Date.now
    public var updatedAt = Date.now
    public var state: SummaryFeedbackState = .queued
    public var message = "已收到，稍后会核对内容。"
    public var attempts = 0
    public var retryAfter: Date?
    public var lease: UUID?
    public var processingRevision: String?
    public var processorVersion: Int?
    public var supplementCaptureID: UUID?
    public var dependencyFeedbackIDs: [UUID]?
    public var sourceVersions: [UUID: String]
    public var resolution: SummaryFeedbackResolution?
    public var resultRevision: String?
    public var dailyBefore: DailySummary?
    public var weeklyBefore: WeeklyReport?
    public var disabledRuleIDs: [UUID] = []
    public init(target: SummaryFeedbackTarget, text: String, sourceVersions: [UUID: String]) {
        self.target = target; self.text = text; self.sourceVersions = sourceVersions
    }
}
public struct SummaryFeedbackSettings: Codable, Equatable, Sendable {
    public var processingEnabled = true
    public var useLearnedRules = true
    public init() {}
}
public enum SummaryFeedbackError: LocalizedError {
    case changed, invalid, rejected
    public var errorDescription: String? {
        switch self {
        case .changed: "回顾或来源已变化，请针对最新内容重新反馈。"
        case .invalid: "反馈处理结果不完整，未修改原内容。"
        case .rejected: "修订尚未通过核对，原内容已保留。"
        }
    }
}
public enum SummaryFeedbackLearning {
    public static func hash<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    public static func hash(_ report: WeeklyReport) -> String {
        // UUID-keyed dictionaries and Sets otherwise encode in process-dependent order.
        var body = report
        body.sourceVersions = [:]; body.scope = ReviewScope()
        let versions = report.sourceVersions.map { $0.key.uuidString + ":" + $0.value }.sorted()
        return hash([hashBody(body), hash(versions), hash(report.scope.topicIDs.sorted()), hash(report.scope.useSelectedTopics)])
    }
    private static func hashBody<T: Encodable>(_ value: T) -> String { hash(value) }
    public static func supplementDate(_ value: SummaryFeedbackSupplement, feedback: SummaryFeedback) -> Date? {
        let calendar = feedback.target.period.calendar
        let day = calendar.startOfDay(for: feedback.createdAt)
        let text = feedback.text
        let expected: Date?
        if text.contains("前天") { expected = calendar.date(byAdding: .day, value: -2, to: day) }
        else if text.contains("昨天") { expected = calendar.date(byAdding: .day, value: -1, to: day) }
        else if text.contains("今天") { expected = day }
        else {
            let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            expected = text.contains(value.occurredOn) ? formatter.date(from: value.occurredOn) : nil
        }
        guard let expected, feedback.target.period.contains(expected), expected <= feedback.createdAt else { return nil }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: expected) == value.occurredOn ? expected : nil
    }
    public static func rawVersion(_ source: CaptureRecord) -> String { MemoryKnowledgeEngine.version(of: source) }
    public static func revision(in state: RecallState) -> String {
        hash(state.summaryFeedback.filter { $0.state == .applied }.map { hash($0.resolution) + hash($0.disabledRuleIDs) }
            + [hash(state.summaryFeedbackSettings)])
    }
    public static func rules(in state: RecallState, kind: SummaryFeedbackKind, templateID: String? = nil, topicID: String? = nil) -> [SummaryLearnedRule] {
        guard state.summaryFeedbackSettings.useLearnedRules else { return [] }
        var result: [String: SummaryLearnedRule] = [:]
        for entry in state.summaryFeedback where entry.state == .applied {
            for rule in entry.resolution?.rules ?? [] {
                guard !entry.disabledRuleIDs.contains(rule.id), rule.allReviews || (rule.reviewKind == kind && rule.templateID == templateID),
                      rule.topicID == nil || rule.topicID == topicID else { continue }
                // Narrow context beats global regardless of which feedback was submitted last.
                if let old = result[rule.kind.dimension], old.topicID != nil && rule.topicID == nil { continue }
                if let old = result[rule.kind.dimension], !old.allReviews && rule.allReviews { continue }
                result[rule.kind.dimension] = rule
            }
        }
        return result.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }
    public static func context(in state: RecallState, kind: SummaryFeedbackKind, templateID: String? = nil, topicID: String? = nil) -> String {
        let policies = rules(in: state, kind: kind, templateID: templateID, topicID: topicID)
        let allowed = Set(state.correctedForAnalysis().captures.map(\.id))
        let cases = state.summaryFeedback.filter { entry in
            entry.state == .applied && entry.target.kind == kind && entry.target.templateID == templateID
                && (entry.target.topicID == nil || entry.target.topicID == topicID)
                && entry.resolution?.diagnosis != .expression
                && Set(entry.sourceVersions.keys).isSubset(of: allowed)
                && entry.sourceVersions.allSatisfy { id, version in
                    state.captures.contains { $0.id == id && rawVersion($0) == version && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }
                }
        }.suffix(4).map { entry in
            "原回顾范围：" + entry.target.period.label + "；相关内容：" + entry.target.items.map(\.title).joined(separator: "；") + "；用户更正（仅限同一事项、同一历史状态，不扩展为新事实）：" + String(entry.text.prefix(400))
        }
        guard !policies.isEmpty || !cases.isEmpty else { return "" }
        return "用户在相同回顾范围内明确提出的要求（不得改变事实、状态和归属；模板篇幅限制仍有效）：\n"
            + (policies.map { "- " + $0.kind.instruction } + cases).joined(separator: "\n")
    }
    /// Analysis-only overlay. Exact, versioned spans change; the saved capture remains inspectable.
    public static func adjusted(_ source: CaptureRecord, in state: RecallState) -> CaptureRecord {
        var result = source
        for entry in state.summaryFeedback where entry.state == .applied {
            guard entry.sourceVersions[source.id] == rawVersion(source) else { continue }
            for change in entry.resolution?.corrections ?? [] where change.sourceID == source.id {
                guard !change.originalQuote.isEmpty, result.ocrText.components(separatedBy: change.originalQuote).count == 2 else { continue }
                result.ocrText = result.ocrText.replacingOccurrences(of: change.originalQuote, with: change.correctedQuote)
                result.summary = nil
                // Manual notes have their own extraction path. Do not silently preserve stale text there.
                if var note = result.manualMatter {
                    note.detail = note.detail.replacingOccurrences(of: change.originalQuote, with: change.correctedQuote)
                    note.title = note.title.replacingOccurrences(of: change.originalQuote, with: change.correctedQuote)
                    if let status = change.status { note.status = status }
                    result.manualMatter = note
                    result.ocrText = "事情：\(note.title)\n状态：\(note.status.manualMatterLabel)\n\(note.detail)"
                }
            }
        }
        return result
    }
    public static func correctionID(for sourceID: UUID, quote: String, in state: RecallState) -> UUID? {
        state.summaryFeedback.last { entry in
            entry.state == .applied && (entry.resolution?.corrections.contains {
                let body = $0.correctedQuote.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
                return $0.sourceID == sourceID && (quote.contains(body) || (quote.count >= 12 && body.contains(quote)))
            } ?? false)
        }?.id
    }
    public static func rejectsAction(title: String, sourceIDs: [UUID], in state: RecallState) -> Bool {
        let key = title.filter { $0.isLetter || $0.isNumber }.lowercased()
        return state.summaryFeedback.contains { entry in
            entry.state == .applied && entry.resolution?.diagnosis == .action
                && (entry.resolution?.changes.contains { change in
                    guard change.remove, let item = entry.target.items.first(where: { $0.id == change.itemID }) else { return false }
                    return item.title.filter { $0.isLetter || $0.isNumber }.lowercased() == key && !Set(item.sourceIDs).isDisjoint(with: sourceIDs)
                } ?? false)
        }
    }
    public static func targetIsCurrent(_ target: SummaryFeedbackTarget, in state: RecallState) -> Bool {
        if target.kind == .daily { return state.dailySummaries.first { $0.id == target.reportID }.map { hash($0) == target.revision } ?? false }
        return state.weeklyReports.first { $0.id == target.reportID && $0.isReadable }.map { hash($0) == target.revision } ?? false
    }
}
