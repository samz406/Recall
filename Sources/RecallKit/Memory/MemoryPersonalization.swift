import Foundation
import CryptoKit

/// A small reading taxonomy. Raw events and saved references belong to their own browsers.
public enum MemoryLibraryCategory: String, CaseIterable, Sendable {
    case all, preferences, agreements, people, experiences
    public var title: String {
        switch self { case .all: "全部记忆"; case .preferences: "偏好与习惯"; case .agreements: "目标与约定"; case .people: "人物信息"; case .experiences: "历史经验" }
    }
    public func includes(_ kind: MemoryClaimKind) -> Bool {
        switch self {
        case .all: return kind.isPersonal || kind == .experience
        case .preferences: return [.preference, .habit, .workflow].contains(kind)
        case .agreements: return [.goal, .constraint].contains(kind)
        case .people: return kind == .person
        case .experiences: return kind == .experience
        }
    }
}

/// Conservative local qualification, not a claim that keywords reveal a person's identity.
/// Temporary requests stay in the source archive, never become global personalization.
public enum MemoryPersonalization {
    public static func isTemporary(_ text: String) -> Bool {
        ["这次", "本次", "今天", "明天", "这周", "本周", "这月", "本月", "暂时", "目前", "近期", "这个版本", "这一版", "这个页面先"].contains(where: text.contains)
    }
    static func isStable(_ text: String, kind: MemoryClaimKind) -> Bool {
        if kind == .person { return true }
        if kind == .goal { return ["长期目标", "我的目标", "我要成为", "未来一年", "接下来一年"].contains(where: text.contains) }
        if kind == .habit { return ["我通常", "我习惯", "我每天", "我每周"].contains(where: text.contains) }
        return ["一直", "一贯", "长期", "以后", "今后", "老规矩", "通常"].contains(where: text.contains)
    }
    static func inferredScope(_ text: String) -> MemoryScope {
        if ["工作周报", "工作总结", "工作中", "工作时"].contains(where: text.contains) { return .work }
        if ["学习时", "学习中", "学英语", "英语练习"].contains(where: text.contains) { return .learning }
        if ["生活中", "个人回顾", "生活回顾", "家人"].contains(where: text.contains) { return .personal }
        return .global
    }
    /// Explicitly named context only. A source app/window title does not define a preference scope.
    static func namedContext(_ text: String) -> (id: String, name: String)? {
        let pattern = #"(?:针对|关于|对于|在)?\s*([A-Za-z][A-Za-z0-9_-]{1,30}|[\p{Han}]{2,12})\s*(?:项目|产品|应用|页面)(?=页面|配色|中|里|的|上|[，,：:\s]|采用|使用|设计|保持)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var name = String(text[range])
        for prefix in ["我希望", "我要求", "我喜欢", "我偏好", "我在", "以后", "今后", "针对", "关于", "对于", "在"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        guard name.count >= 2, !["这个", "当前", "所有", "全部", "任何", "每个", "一个"].contains(name) else { return nil }
        let digest = SHA256.hash(data: Data(MemoryDirective.normalized(name).utf8)).map { String(format: "%02x", $0) }.joined()
        return ("context:" + digest, name)
    }
    /// Resolving aliases/nearby text is deliberately not enough: require an explicit subject mention.
    static func context(_ text: String, entities: [MemoryEntity]) -> (id: String, name: String)? {
        if let match = entities.filter({ $0.kind == "topic" && $0.name.count >= 3 }).sorted(by: { $0.name.count > $1.name.count }).first(where: { entity in
            ([entity.name] + entity.aliases).contains { $0.count >= 3 && text.localizedCaseInsensitiveContains($0) }
        }) { return (match.id, match.name) }
        return namedContext(text)
    }
    static func polarityObject(_ text: String) -> String? {
        let patterns = ["我不再喜欢", "我不喜欢", "我一直喜欢", "我长期偏好", "我更喜欢", "我喜欢", "我偏好"]
        guard let marker = patterns.first(where: text.contains), let range = text.range(of: marker) else { return nil }
        let object = MemoryDirective.normalized(String(text[range.upperBound...]))
        return object.count >= 2 ? object : nil
    }
    static func isNegative(_ text: String) -> Bool { text.contains("我不喜欢") || text.contains("我不再喜欢") }
    static func questionScope(_ question: String) -> MemoryScope {
        if ["周报", "工作", "交付", "项目", "代码"].contains(where: question.contains) { return .work }
        if ["学习", "练习", "英语"].contains(where: question.contains) { return .learning }
        if ["生活", "个人回顾", "家人"].contains(where: question.contains) { return .personal }
        return .global
    }
    static func applies(_ claim: MemoryClaim, question: String, entities: Set<String>, conversationID: UUID?) -> Bool {
        switch claim.scope {
        case .global: return true
        case .conversation: return conversationID != nil && claim.scopeID == conversationID?.uuidString
        case .project: return claim.scopeID.map(entities.contains) ?? false
        default: return claim.scope == questionScope(question)
        }
    }
    static func preferenceSlot(_ content: String) -> String? {
        if ["简洁", "详细", "篇幅", "少换行", "精简", "简短"].contains(where: content.contains) { return "response-length" }
        if ["正式", "自然", "语气", "口吻"].contains(where: content.contains) { return "response-tone" }
        if ["中文", "英文", "语言"].contains(where: content.contains) { return "response-language" }
        return nil
    }
    static func effectiveScopeID(_ directive: MemoryDirective, entities: [MemoryEntity]) -> (MemoryScope, String?) {
        guard directive.scope == .global, directive.scopeExplicitlySet != true,
              let target = context(directive.content, entities: entities) else { return (directive.scope, directive.scopeID) }
        return (.project, target.id)
    }
}
