import Foundation
import CryptoKit

/// Report-level grouping only: original candidates, source dates and attribution stay intact.
/// It never changes the user's topic library or manufactures a combined completion state.
public enum ReviewConsolidation {
    public static func local(_ items: [ReviewItem]) -> [ReviewItem] {
        let originals = items.filter { $0.memberTopicIDs == nil }
        let groups = Dictionary(grouping: originals) { anchor($0.title) ?? $0.id }
        var result = items
        for (title, members) in groups.sorted(by: { $0.key < $1.key }) where members.count > 1 && members.count <= 8 {
            guard members.allSatisfy({ anchor($0.title) == title }),
                  let item = combine(members, title: title, local: true), !result.contains(where: { $0.id == item.id }) else { continue }
            result.append(item)
        }
        return result
    }
    private static func anchor(_ title: String) -> String? {
        // Explicit object-qualified headings such as “Atlas 发布流程 · 步骤导航”.
        // A product name, app name or shared word like “页面/优化” alone is insufficient.
        let parts = title.components(separatedBy: " · ")
        guard parts.count > 1 else { return nil }
        let prefix = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...50).contains(prefix.count),
              prefix.range(of: #"流程|接口|订单|发布|验收|导出|支付|计划|课程"#, options: .regularExpression) != nil else { return nil }
        return prefix
    }
    public static func combine(_ members: [ReviewItem], title: String, local: Bool = false) -> ReviewItem? {
        guard (2...8).contains(members.count), Set(members.map(\.id)).count == members.count,
              members.allSatisfy({ $0.memberTopicIDs == nil }), ReviewDigest.meaningfulTitle(title),
              Set(members.map(\.category)).count == 1,
              Set(members.map { $0.id.hasPrefix("reference:") }).count == 1 else { return nil }
        var seen: Set<UUID> = []
        let excerpts = members.flatMap(\.excerpts).sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }.filter { seen.insert($0.id).inserted }
        let required = Set(members.flatMap(\.requiredExcerptIDs))
        guard required.count <= 16 else { return nil }
        let ids = members.map(\.id).sorted()
        let hash = SHA256.hash(data: Data(ids.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
        let prefix = members[0].id.hasPrefix("reference:") ? "reference:review-group:" : "review-group:"
        let section: ReviewSection
        if members.contains(where: { $0.section == .open }) { section = .open }
        else if members.contains(where: { $0.section == .progress }) { section = .progress }
        else if members.contains(where: { $0.section == .plans }) { section = .plans }
        else { section = .notes }
        let actions = members.compactMap(\.nextAction).memoryUnique()
        return ReviewItem(id: prefix + hash, title: title, category: members[0].category, section: section,
            previous: members.compactMap(\.previous).max(by: { $0.date < $1.date }), excerpts: excerpts,
            featuredIDs: excerpts.filter { required.contains($0.id) }.map(\.id),
            nextAction: actions.isEmpty ? nil : actions.joined(separator: "\n"),
            nextActionSourceIDs: members.flatMap(\.nextActionSourceIDs).memoryUnique(),
            memberTopicIDs: ids, consolidatedRequiredIDs: excerpts.filter { required.contains($0.id) }.map(\.id),
            locallyGrouped: local)
    }
}
