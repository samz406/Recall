import Foundation

/// Reading budgets apply to the entire report. The evidence ledger stays lossless.
public extension ReviewLength {
    var itemLimit: Int { switch self { case .brief: 3; case .standard: 5; case .detailed: 8 } }
    var summaryLimit: Int { switch self { case .brief: 120; case .standard: 180; case .detailed: 300 } }
    var bodyLimit: Int { switch self { case .brief: 800; case .standard: 1_400; case .detailed: 2_800 } }
    var explanation: String { "整份最多 \(itemLimit) 项重点；每项正文不超过 \(summaryLimit) 字，完整过程在依据中查看。" }
}

public struct ReviewDigestRow: Identifiable, Sendable {
    public var item: ReviewItem
    public var title: String
    public var summary: String
    public var action: String?
    public var isExtractive: Bool
    public var id: String { item.id }
    public var characterCount: Int { title.count + summary.count + (action?.count ?? 0) }
}

/// A projection, not a deletion or a claim that every candidate is a real-life topic.
/// Unknown ownership is never upgraded to an accomplishment in the local fallback.
public enum ReviewDigest {
    private struct Candidate {
        let item: ReviewItem
        let days: Set<Date>
        let score: Int
        let key: String
    }
    public static func candidates(_ items: [ReviewItem], period: ReviewPeriod, limit: Int) -> [ReviewItem] {
        var candidates: [Candidate] = []
        let groupedMembers = Set(items.flatMap { $0.memberTopicIDs ?? [] })
        for item in items where !groupedMembers.contains(item.id) {
            guard meaningfulTitle(item.displayTitle), !item.excerpts.isEmpty,
                  item.excerpts.contains(where: { readable($0.text) }) else { continue }
            let days = Set(item.excerpts.map { period.calendar.startOfDay(for: $0.date) })
            let states = Set(item.excerpts.map { $0.status.rawValue }).count
            // A grouped item whose id carries the reference prefix may still contain the user's own matters.
            let ownedMembers = item.excerpts.contains { !$0.text.hasPrefix("保存的内容（归属与实际状态未确认）") }
            var score = item.id.hasPrefix("reference:") && !ownedMembers ? 0 : 30
            score += item.importance * 6 + min(days.count, 7) * 2 + min(states, 3) * 3
            if item.nextAction != nil { score += 4 }
            candidates.append(Candidate(item: item, days: days, score: score, key: duplicateKey(item)))
        }
        let ranked = candidates.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let first = a.item.excerpts.last?.date ?? .distantPast
            let second = b.item.excerpts.last?.date ?? .distantPast
            return first == second ? a.item.id < b.item.id : first > second
        }
        // Metadata and duplicate keys are computed once, not for every comparison in a view.
        var result: [ReviewItem] = [], days: Set<Date> = [], categories: Set<ReviewCategory> = []
        var seenIDs: Set<String> = [], seenKeys: Set<String> = []
        func append(_ row: Candidate) {
            guard result.count < limit, !seenIDs.contains(row.item.id), !seenKeys.contains(row.key) else { return }
            result.append(row.item); seenIDs.insert(row.item.id); seenKeys.insert(row.key)
            days.formUnion(row.days); categories.insert(row.item.category)
        }
        let owned = ranked.filter { !$0.item.id.hasPrefix("reference:") }
        if let first = owned.first ?? ranked.first { append(first) }
        for row in owned where !categories.contains(row.item.category) { append(row) }
        for row in ranked where row.days.isDisjoint(with: days) { append(row) }
        for row in ranked { append(row) }
        return result
    }

    public static func rows(items: [ReviewItem], selectedIDs: [String]?, period: ReviewPeriod, length: ReviewLength) -> [ReviewDigestRow] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected: [ReviewItem]
        if let selectedIDs { selected = selectedIDs.compactMap { byID[$0] } }
        else { selected = candidates(items, period: period, limit: items.count) }
        var rows: [ReviewDigestRow] = [], remaining = length.bodyLimit
        for item in selected {
            if rows.count == length.itemLimit { break }
            guard !rows.contains(where: { duplicate($0.item, item) }),
                  let row = row(item, length: length), row.characterCount <= remaining else { continue }
            rows.append(row); remaining -= row.characterCount
        }
        return rows
    }

    public static func row(_ item: ReviewItem, length: ReviewLength) -> ReviewDigestRow? {
        let title = clean(item.displayTitle)
        guard item.memberTopicIDs == nil || item.locallyGrouped == true || item.narrative != nil else { return nil }
        guard meaningfulTitle(title) else { return nil }
        let summary: String
        let extractive: Bool
        if let narrative = item.narrative {
            // No mid-sentence clipping or hidden omission of a condition/negative state.
            let text = clean(narrative.summary)
            guard (12...length.summaryLimit).contains(text.count), readable(text) else { return nil }
            summary = text; extractive = false
        } else {
            guard !item.id.hasPrefix("reference:") else { return nil }
            let required = Set(item.requiredExcerptIDs)
            let parts = item.excerpts.filter { required.contains($0.id) }.map { clean($0.text) }
            guard !parts.isEmpty, parts.allSatisfy({ readable($0) && !$0.contains("归属与实际状态未确认") }) else { return nil }
            var unique: [String] = []
            var keys = Set<String>()
            // Same sentence modulo spacing/punctuation is one event, not two.
            for part in parts where keys.insert(MatterEvidence.key(part)).inserted { unique.append(part) }
            let text = unique.joined(separator: "\n")
            guard (8...length.summaryLimit).contains(text.count) else { return nil }
            summary = text == title ? "" : text; extractive = true
        }
        // Long or incomplete next actions stay in the evidence viewer, never a broken headline.
        let action = item.nextAction.map(clean).flatMap { value in
            value.count <= 120 && readable(value) && value != summary && value != title ? value : nil
        }
        return ReviewDigestRow(item: item, title: title, summary: summary, action: action, isExtractive: extractive)
    }

    public static func meaningfulTitle(_ raw: String) -> Bool {
        let text = clean(raw)
        guard (3...70).contains(text.count), !text.contains("\n"), readable(text),
              text.range(of: #"^(?:保存的内容|本地记录|记录主题|未分类|这里|这个|那个|然后|还有|都空|的一|3\.|\d+[、.)])"#, options: .regularExpression) == nil,
              text.range(of: #"^(?:发布日期|提交记录|申请时间|import |public |private |func |const |let )|https?://|[{}]|(?:\.mp4|\.png|\.swift|\.java)$"#, options: .regularExpression) == nil else { return false }
        return true
    }

    static func readable(_ raw: String) -> Bool {
        let text = clean(raw)
        return text.count >= 3 && !text.contains("�") && !text.contains("```")
            && !text.hasSuffix("…") && !text.hasSuffix("...")
            && text.range(of: #"[×|]{2}|(?:通讯录|工作台|微盘|智能助理).*(?:通讯录|工作台|微盘|智能助理)|网络异常.*再试"#, options: .regularExpression) == nil
    }
    static func clean(_ text: String) -> String {
        DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(from: DailySummaryContentFormatter.removingCitationMarkers(from: text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func duplicateKey(_ item: ReviewItem) -> String {
        let texts = Set(item.excerpts.map { MatterEvidence.key($0.text) }).sorted()
        return MatterEvidence.key(item.title) + "|" + item.section.rawValue + "|" + texts.joined(separator: "\n")
    }
    private static func duplicate(_ a: ReviewItem, _ b: ReviewItem) -> Bool {
        a.id == b.id || duplicateKey(a) == duplicateKey(b)
    }

}

public extension WeeklyReport {
    var digestRows: [ReviewDigestRow] {
        guard isReadable else { return [] }
        return ReviewDigest.rows(items: items, selectedIDs: digestTopicIDs, period: period, length: template.length)
    }
    var coveredDayCount: Int {
        Set(items.flatMap(\.excerpts).map { period.calendar.startOfDay(for: $0.date) }).count
    }
    var digestOverview: String {
        let titles = digestRows.prefix(3).map(\.title)
        guard !titles.isEmpty else { return "本期记录暂未形成可靠的小结。可以查看整理依据，或重新生成回顾。" }
        return "本期重点：" + titles.joined(separator: "；") + "。"
    }
}
