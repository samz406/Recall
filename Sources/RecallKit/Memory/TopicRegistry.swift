import Foundation

/// 主题的稳定身份。合并组、完成标记、小结都挂在 `id` 上；
/// `title` 是可演进的显示名，旧名进入 `aliases`，身份不变。
public struct Topic: Codable, Equatable, Identifiable, Sendable {
    public enum Lifecycle: String, Codable, CaseIterable, Sendable { case active, dormant, done, archived }

    public var id: UUID
    public var title: String
    /// 曾用名与合并进来的名字。比较时按 `DailyKnowledgeEngine.topicKey` 规范化。
    public var aliases: [String]
    public var lifecycle: Lifecycle
    /// 用户手动标记，优先于推断。
    public var manualLifecycle: Lifecycle?
    /// 项目层级：两级（项目 → 主题）。
    public var parentID: UUID?
    /// 项目只是容器，没有自己的事件。
    public var isProject: Bool
    public var createdAt: Date
    public var lastEventAt: Date?

    public init(id: UUID = UUID(), title: String, aliases: [String] = [], lifecycle: Lifecycle = .active,
                manualLifecycle: Lifecycle? = nil, parentID: UUID? = nil, isProject: Bool = false,
                createdAt: Date = .now, lastEventAt: Date? = nil) {
        self.id = id; self.title = title; self.aliases = aliases; self.lifecycle = lifecycle
        self.manualLifecycle = manualLifecycle; self.parentID = parentID; self.isProject = isProject
        self.createdAt = createdAt; self.lastEventAt = lastEventAt
    }
}

/// 主题登记表。只保存名字与状态，不保存任何原文。
public struct TopicRegistry: Codable, Equatable, Sendable {
    public var topics: [Topic] = []
    /// 旧的主题 ID（`topic:<规范键>`）→ 稳定 UUID，迁移后旧引用继续有效。
    public var legacyAliases: [String: UUID] = [:]

    public init() {}
    public init(topics: [Topic], legacyAliases: [String: UUID] = [:]) {
        self.topics = topics
        self.legacyAliases = legacyAliases
    }

    public func topic(id: UUID) -> Topic? { topics.first { $0.id == id } }

    /// 按名字查主题：显示名与别名都比规范键。
    public func topic(forName name: String) -> Topic? {
        let key = DailyKnowledgeEngine.topicKey(name)
        return topics.first { topic in
            DailyKnowledgeEngine.topicKey(topic.title) == key
                || topic.aliases.contains { DailyKnowledgeEngine.topicKey($0) == key }
        }
    }

    /// 项目下的主题（不含项目本身）。
    public func children(of projectID: UUID) -> [Topic] {
        topics.filter { $0.parentID == projectID && !$0.isProject }
    }

    /// 删除项目：子主题回到顶层，不连带删除。
    public mutating func deleteProject(id: UUID) {
        guard let project = topic(id: id), project.isProject else { return }
        for i in topics.indices where topics[i].parentID == id { topics[i].parentID = nil }
        remove(id: id)
    }

    public func topic(forLegacyID legacyID: String) -> Topic? {
        guard let id = legacyAliases[legacyID] else { return nil }
        return topic(id: id)
    }

    /// 把旧的 `topic:<键>` 引用改写成稳定 ID；不是旧键时原样返回。
    public func rewritten(_ legacyID: String) -> String { canonicalID(legacyID) }

    /// 旧 ID 归一：`topic:<uuid>` 原样返回；旧键命中迁移表则返回新 ID；其余原样返回。
    public func canonicalID(_ id: String) -> String {
        guard id.hasPrefix("topic:") else { return id }
        if let mapped = legacyAliases[id] { return "topic:" + mapped.uuidString }
        return id
    }

    public mutating func upsert(_ topic: Topic) {
        if let index = topics.firstIndex(where: { $0.id == topic.id }) { topics[index] = topic }
        else { topics.append(topic) }
    }

    @discardableResult
    public mutating func resolveOrCreate(name: String, at date: Date = .now) -> Topic {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = topic(forName: trimmed) { return existing }
        let topic = Topic(title: trimmed, createdAt: date, lastEventAt: date)
        topics.append(topic)
        return topic
    }

    /// 改名只更新显示名，旧名进入别名，ID 不变。
    public mutating func rename(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = topics.firstIndex(where: { $0.id == id }) else { return }
        let old = topics[index].title
        guard DailyKnowledgeEngine.topicKey(old) != DailyKnowledgeEngine.topicKey(trimmed) else {
            topics[index].title = trimmed
            return
        }
        topics[index].title = trimmed
        if !topics[index].aliases.contains(where: { DailyKnowledgeEngine.topicKey($0) == DailyKnowledgeEngine.topicKey(old) }) {
            topics[index].aliases.append(old)
        }
    }

    /// 把 source 并进 target：名字进入别名，子主题改挂到目标，然后删除源。
    public mutating func merge(_ sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID, let source = topic(id: sourceID), let target = topic(id: targetID) else { return }
        guard let index = topics.firstIndex(where: { $0.id == targetID }) else { return }
        var names = topics[index].aliases + [source.title] + source.aliases + [target.title]
        // 目标自己的名字不该进入别名；其余去重保留。
        names.removeAll { DailyKnowledgeEngine.topicKey($0) == DailyKnowledgeEngine.topicKey(target.title) }
        var unique: [String] = []
        for name in names where !unique.contains(where: { DailyKnowledgeEngine.topicKey($0) == DailyKnowledgeEngine.topicKey(name) }) {
            unique.append(name)
        }
        topics[index].aliases = unique
        if let sourceDate = source.lastEventAt, let targetDate = topics[index].lastEventAt {
            topics[index].lastEventAt = max(sourceDate, targetDate)
        } else if topics[index].lastEventAt == nil {
            topics[index].lastEventAt = source.lastEventAt
        }
        if source.parentID != nil, topics[index].parentID == nil { topics[index].parentID = source.parentID }
        for i in topics.indices where topics[i].parentID == sourceID { topics[i].parentID = targetID }
        for (legacy, id) in legacyAliases where id == sourceID { legacyAliases[legacy] = targetID }
        topics.removeAll { $0.id == sourceID }
    }

    /// 删除主题：别名随之消失，挂在它下面的子主题改挂到顶层，不连带删除原始记录。
    public mutating func remove(id: UUID) {
        topics.removeAll { $0.id == id }
        for i in topics.indices where topics[i].parentID == id { topics[i].parentID = nil }
        for (legacy, mapped) in legacyAliases where mapped == id { legacyAliases.removeValue(forKey: legacy) }
    }

    /// 设置两级项目归属。拒绝自指与成环，成功返回 true。
    @discardableResult
    public mutating func setParent(_ parentID: UUID?, of id: UUID) -> Bool {
        guard let index = topics.firstIndex(where: { $0.id == id }) else { return false }
        guard let parentID else { topics[index].parentID = nil; return true }
        guard parentID != id, let parentIndex = topics.firstIndex(where: { $0.id == parentID }) else { return false }
        // 只允许两级：父必须是项目，且项目自己不能再有父。
        guard topics[parentIndex].isProject, topics[parentIndex].parentID == nil else { return false }
        topics[index].parentID = parentID
        return true
    }

    /// 状态推断：用户手动标记优先；最近事件已完成算完成；14 天没有动静算搁置；
    /// 之后出现新事件会自动回到进行中，因为每次投影都重新推断。
    public static func lifecycle(for file: MatterFile, topic: Topic?, now: Date = .now,
                                 calendar: Calendar = .current) -> Topic.Lifecycle {
        if let manual = topic?.manualLifecycle { return manual }
        if file.latest.status == .completed { return .done }
        if file.needsStatusUpdate(at: now, calendar: calendar) { return .dormant }
        return .active
    }

    /// 从现有每日回顾迁移。同一存档多次迁移得到同一组 UUID。
    public static func migrated(from state: RecallState, now: Date = .now) -> TopicRegistry {
        var registry = TopicRegistry()
        let files = DailyKnowledgeEngine().matterFiles(in: state)
        guard !files.isEmpty else { return registry }
        let anchor = UUID(uuidString: "6F1B2C6A-3E31-4E7D-9E2C-8A1B5C7D9E01")!
        for file in files {
            let id = MatterEvidence.eventID(source: anchor, topic: "registry|" + file.id, ordinal: 0)
            let key = file.id.hasPrefix("topic:") ? String(file.id.dropFirst("topic:".count)) : file.id
            var aliases = state.topicAliases
                .filter { $0.value == key && $0.key != key }
                .map(\.key)
            aliases = aliases.filter { DailyKnowledgeEngine.topicKey($0) != DailyKnowledgeEngine.topicKey(file.title) }
            registry.topics.append(Topic(id: id, title: file.title, aliases: aliases.sorted(),
                lifecycle: .active, createdAt: file.events.first?.date ?? now, lastEventAt: file.latest.date))
            registry.legacyAliases[file.id] = id
        }
        return registry
    }
}
