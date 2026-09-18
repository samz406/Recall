import Foundation

public enum DailySummaryGenerationKind: String, Codable, Sendable {
    case cloud
    case localFallback
}

public enum DailySummaryContentFormatter {
    /// 每日总结的证据关联保存在 `sourceCaptureIDs`，正文不再显示干扰阅读的 `[1][2]` 编号。
    public static func removingCitationMarkers(from content: String) -> String {
        content.replacingOccurrences(
            of: #"[ \t]*\[(?:\d+[ \t,，、\-–—]*)+\]"#,
            with: "",
            options: .regularExpression
        )
    }

    /// 结构化条目最终由 SwiftUI `Text` 展示，不再经过 Markdown 渲染。
    /// 模型偶尔仍会返回 `**标题**`，因此在进入数据模型时统一移除强调标记。
    public static func removingMarkdownEmphasisMarkers(from content: String) -> String {
        content.replacingOccurrences(of: "**", with: "")
    }

    /// 兼容旧版 Markdown：把“未闭环/待办/近 14 天/下一步”统一归入行动事项，
    /// 并过滤“今天”“继续”这类无法执行的占位词。
    public static func normalizingNextActionSection(
        in content: String,
        fallbackActions: [String] = []
    ) -> String {
        let lines = removingAbstractCarryOverItems(
            from: removingCitationMarkers(from: content)
        ).components(separatedBy: .newlines)
        var body: [String] = []
        var modelActions: [String] = []
        var readingActions = false

        for line in lines {
            if let heading = markdownHeadingTitle(line) {
                if isActionHeading(heading) {
                    readingActions = true
                    continue
                }
                readingActions = false
            }
            if readingActions {
                modelActions.append(line)
            } else {
                body.append(line)
            }
        }

        while body.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            body.removeLast()
        }
        let actions = validatedNextActions(from: modelActions + fallbackActions)
        guard !actions.isEmpty else { return body.joined(separator: "\n") }
        return (body + ["", "## 接下来要处理", ""] + actions.map { "- \($0)" }).joined(separator: "\n")
    }

    public static func validatedNextActions(from candidates: [String], limit: Int = 3) -> [String] {
        var seen: Set<String> = []
        return candidates.compactMap(normalizedAction)
            .filter { action in
                let key = action
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
                    .lowercased()
                return seen.insert(key).inserted
            }
            .prefix(max(limit, 1))
            .map { $0 }
    }

    private static func markdownHeadingTitle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        return trimmed
            .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isActionHeading(_ heading: String) -> Bool {
        let normalized = heading.replacingOccurrences(of: #"[\s：:]"#, with: "", options: .regularExpression)
        return [
            "接下来要处理", "尚未闭环", "未闭环", "待办与提醒", "待办", "近14天提醒与建议",
            "需要继续跟进", "下一步", "下一步行动", "建议先做", "明天先做"
        ].contains(normalized)
    }

    private static func removingAbstractCarryOverItems(from content: String) -> String {
        let abstractDirections = ["产品方向", "改进方向", "设计理念", "愿景", "以系统流程为中心", "以用户为中心"]
        var readingCarryOver = false
        return content.components(separatedBy: .newlines).filter { line in
            if let heading = markdownHeadingTitle(line) {
                let normalized = heading.replacingOccurrences(of: #"[\s：:]"#, with: "", options: .regularExpression)
                readingCarryOver = ["近14天提醒与建议", "需要继续跟进"].contains(normalized)
                return true
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard readingCarryOver, trimmed.hasPrefix("-") || trimmed.hasPrefix("*") else { return true }
            return !abstractDirections.contains(where: line.contains)
        }.joined(separator: "\n")
    }

    private static func normalizedAction(_ candidate: String) -> String? {
        var action = candidate
            .replacingOccurrences(of: #"^\s*(?:[-*•]+|\d+[.、)])\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n:：·-—"))
        let parts = action.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "：" }).map(String.init)
        if parts.count == 2, isNoiseTitle(parts[0]) {
            action = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let compact = action.replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
        guard compact.count >= 4, compact.count <= 120 else { return nil }
        let generic = ["今天", "明天", "后天", "本周", "下周", "近期", "以后", "后续", "继续", "处理", "推进", "看看", "待办", "待确认", "暂无", "没有", "无"]
        guard !generic.contains(compact) else { return nil }
        let abstractDirections = ["产品方向", "改进方向", "设计理念", "愿景", "以系统流程为中心", "以用户为中心"]
        guard !abstractDirections.contains(where: action.contains) else { return nil }
        guard compact.range(
            of: #"^(?:今天|明天|后天|本周|下周|近期|以后|后续)(?:再)?(?:继续|处理|推进|看看|确认)?$"#,
            options: .regularExpression
        ) == nil else { return nil }
        let actionCues = [
            "完成", "修复", "确认", "联系", "回复", "提交", "评审", "验证", "整理", "安排", "决定", "选择", "下单",
            "输出", "拆分", "关闭", "更新", "跟进", "检查", "创建", "推进", "解决", "补充", "复盘", "记录", "归档",
            "预约", "约", "购买", "发送", "实现", "优化", "发布", "测试", "接入", "迁移", "准备", "讨论", "调研",
            "编写", "阅读", "学习", "练习"
        ]
        guard actionCues.contains(where: action.contains) else { return nil }
        return action
    }

    fileprivate static func isNoiseTitle(_ text: String) -> Bool {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.range(of: #"^[A-Za-z0-9]$"#, options: .regularExpression) != nil
    }
}

public enum DailySummaryTodoPriority: String, Codable, Hashable, Sendable {
    case high
    case normal

    public var title: String {
        switch self {
        case .high: "建议先做"
        case .normal: "待办"
        }
    }
}

public enum DailySummaryActionStatus: String, Codable, Hashable, Sendable {
    case pending
    case inProgress
    case completed
    case ignored
}

/// 每日总结中的统一行动事项。截止时间、提醒时间和优先级是事项属性，
/// 不再各自生成一个内容板块。类型名保留 `Todo`，以兼容已经保存的数据。
public struct DailySummaryTodo: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var status: DailySummaryActionStatus
    public var dueAt: Date?
    public var reminderAt: Date?
    public var sourceCaptureIDs: [UUID]
    public var priority: DailySummaryTodoPriority
    public var firstSeenAt: Date?
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        status: DailySummaryActionStatus = .pending,
        dueAt: Date? = nil,
        reminderAt: Date? = nil,
        sourceCaptureIDs: [UUID] = [],
        priority: DailySummaryTodoPriority,
        firstSeenAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.dueAt = dueAt
        self.reminderAt = reminderAt
        self.sourceCaptureIDs = sourceCaptureIDs
        self.priority = priority
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, detail, status, dueAt, reminderAt, sourceCaptureIDs, priority, firstSeenAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        status = try container.decodeIfPresent(DailySummaryActionStatus.self, forKey: .status) ?? .pending
        dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        reminderAt = try container.decodeIfPresent(Date.self, forKey: .reminderAt)
        sourceCaptureIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceCaptureIDs) ?? []
        priority = try container.decodeIfPresent(DailySummaryTodoPriority.self, forKey: .priority) ?? .normal
        firstSeenAt = try container.decodeIfPresent(Date.self, forKey: .firstSeenAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

public enum DailySummarySection: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    /// 新版每日总结只写入并展示这三个维度。
    case actions
    case headline
    case progress
    case openLoops
    case insights
    case todos
    case recent
    case nextActions

    public var id: String { rawValue }

    public static var displaySections: [DailySummarySection] { [.progress, .actions, .insights] }

    public var canonical: DailySummarySection {
        switch self {
        case .headline, .progress: .progress
        case .openLoops, .todos, .recent, .nextActions, .actions: .actions
        case .insights: .insights
        }
    }

    public var title: String {
        switch self {
        case .headline, .progress: "今天推进了什么"
        case .openLoops, .todos, .recent, .nextActions, .actions: "接下来要处理"
        case .insights: "值得留意"
        }
    }

    public var systemImage: String {
        switch self {
        case .headline: "scope"
        case .progress: "checkmark.seal.fill"
        case .openLoops: "circle.dashed"
        case .insights: "sparkles"
        case .todos, .actions: "checklist"
        case .recent: "calendar.badge.clock"
        case .nextActions: "arrow.up.right.circle.fill"
        }
    }
}

public struct DailySummaryItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var section: DailySummarySection
    public var title: String
    public var detail: String
    public var evidenceIDs: [UUID]

    public init(
        id: UUID = UUID(),
        section: DailySummarySection,
        title: String,
        detail: String = "",
        evidenceIDs: [UUID] = []
    ) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
        self.evidenceIDs = evidenceIDs
    }
}

public enum DailySummaryItemParser {
    /// 新版模型协议使用结构化 JSON；字段缺失或模型包裹了代码块时也能安全解析。
    public static func itemsFromModelResponse(
        _ content: String,
        defaultEvidenceIDs: [UUID]
    ) -> [DailySummaryItem]? {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start <= end,
              let data = String(content[start...end]).data(using: .utf8),
              let response = try? JSONDecoder().decode(DailySummaryModelResponse.self, from: data) else {
            return nil
        }
        var items: [DailySummaryItem] = []
        if let headline = response.headline?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty {
            items.append(DailySummaryItem(section: .progress, title: headline, evidenceIDs: defaultEvidenceIDs))
        }
        items.append(contentsOf: response.progress.compactMap { value in
            modelItem(value, section: .progress, evidenceIDs: defaultEvidenceIDs)
        })
        items.append(contentsOf: response.actions.compactMap { value in
            modelItem(value, section: .actions, evidenceIDs: defaultEvidenceIDs)
        })
        items.append(contentsOf: response.insights.compactMap { value in
            guard (value.confidence ?? 0.7) >= 0.55,
                  var item = modelItem(value, section: .insights, evidenceIDs: defaultEvidenceIDs) else { return nil }
            if let confidence = value.confidence, confidence < 0.75, !item.title.hasPrefix("可能") {
                item.title = "可能：\(item.title)"
            }
            return item
        })
        let sanitizedItems = sanitized(items)
        return sanitizedItems.isEmpty ? nil : sanitizedItems
    }

    /// 将模型 Markdown 转成可单项治理的数据。旧总结会在首次加载时自动完成迁移。
    public static func items(from content: String, defaultEvidenceIDs: [UUID]) -> [DailySummaryItem] {
        var currentSection: DailySummarySection?
        var result: [DailySummaryItem] = []
        for rawLine in DailySummaryContentFormatter.removingCitationMarkers(from: content).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                currentSection = section(for: line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let currentSection else { continue }
            let cleaned = line.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\d+[\.、]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 2, !isPlaceholder(cleaned) else { continue }
            let parts = cleaned.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "：" }).map(String.init)
            // 单句就是完整事项，不再按字符数猜测标题。只有明确存在“标题：说明”时才拆分。
            var title = parts.count == 2 ? parts[0] : cleaned
            var detail = parts.count == 2 ? parts[1] : ""
            if DailySummaryContentFormatter.isNoiseTitle(title), !detail.isEmpty {
                title = detail
                detail = ""
            }
            result.append(DailySummaryItem(
                section: currentSection,
                title: title,
                detail: detail,
                evidenceIDs: defaultEvidenceIDs
            ))
        }
        return result
    }

    public static func items(
        from content: String,
        briefing: DailyBriefing?,
        todos: [DailySummaryTodo],
        defaultEvidenceIDs: [UUID]
    ) -> [DailySummaryItem] {
        var parsed = items(from: content, defaultEvidenceIDs: defaultEvidenceIDs)
        var evidence: [(text: String, ids: [UUID])] = todos.map { ("\($0.title) \($0.detail)", $0.sourceCaptureIDs) }
        if let briefing {
            evidence.append(contentsOf: briefing.progress.map { ("\($0.title) \($0.detail)", $0.evidenceIDs) })
            evidence.append(contentsOf: briefing.openLoops.map { ("\($0.title) \($0.detail)", $0.evidenceIDs) })
            evidence.append(contentsOf: briefing.nextActions.map { ("\($0.title) \($0.detail)", $0.evidenceIDs) })
            evidence.append(contentsOf: briefing.insights.map { ("\($0.title) \($0.detail)", $0.evidenceIDs) })
        }
        for index in parsed.indices {
            let itemText = normalized("\(parsed[index].title) \(parsed[index].detail)")
            guard let match = evidence.first(where: { candidate in
                let candidateText = normalized(candidate.text)
                return candidate.ids.isEmpty == false && (
                    candidateText.contains(itemText) || itemText.contains(candidateText) ||
                    overlap(itemText, candidateText) >= 2
                )
            }) else { continue }
            parsed[index].evidenceIDs = match.ids
        }
        return parsed
    }

    public static func markdown(from items: [DailySummaryItem]) -> String {
        let items = sanitized(items)
        return DailySummarySection.displaySections.compactMap { section in
            let values = items.filter { $0.section == section }
            guard !values.isEmpty else { return nil }
            let lines = values.map { item in
                item.detail.isEmpty || item.detail == item.title
                    ? "- \(item.title)"
                    : "- \(item.title)：\(item.detail)"
            }
            return "## \(section.title)\n\n" + lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// 将旧版七类总结迁移到三个用户维度，并在迁移过程中清理重复和算法术语。
    public static func sanitized(_ items: [DailySummaryItem]) -> [DailySummaryItem] {
        var result: [DailySummaryItem] = []
        for original in items {
            var item = original
            item.section = item.section.canonical
            item.title = DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(from: item.title)
            item.detail = DailySummaryContentFormatter.removingMarkdownEmphasisMarkers(from: item.detail)
            if DailySummaryContentFormatter.isNoiseTitle(item.title), !item.detail.isEmpty {
                item.title = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                item.detail = ""
            }
            if item.section == .actions {
                item.title = item.title.replacingOccurrences(
                    of: #"^(?:【(?:优先处理|建议先做|待办)】\s*|(?:未闭环|阻塞|建议)\s*[·：:]\s*)"#,
                    with: "",
                    options: .regularExpression
                )
                if isCategoricalActionTitle(item.title), !item.detail.isEmpty {
                    item.title = item.detail
                    item.detail = ""
                }
            }
            if item.section == .insights, isAlgorithmLabel(item.title) {
                guard isConcreteInsight(item.detail) else { continue }
                item.title = item.detail
                item.detail = ""
            }
            item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            item.detail = item.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            repairLegacyPrefixDuplication(in: &item)
            guard !item.title.isEmpty else { continue }

            if let duplicateIndex = result.firstIndex(where: { isDuplicate($0, item) }) {
                var existing = result[duplicateIndex]
                if item.detail.count > existing.detail.count { existing.detail = item.detail }
                existing.evidenceIDs = Array(Set(existing.evidenceIDs + item.evidenceIDs))
                result[duplicateIndex] = existing
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// 旧版曾把无冒号的长句截成前 42 个字符作为标题，同时把完整句子放进详情。
    /// 已保存的数据仍会带着这个形态；加载时恢复完整标题并清空重复详情。
    private static func repairLegacyPrefixDuplication(in item: inout DailySummaryItem) {
        guard !item.detail.isEmpty else { return }
        if item.detail == item.title || item.detail.hasPrefix(item.title) {
            item.title = item.detail
            item.detail = ""
        } else if item.title.hasPrefix(item.detail) {
            item.detail = ""
        }
    }

    private static func isCategoricalActionTitle(_ title: String) -> Bool {
        let normalized = title.replacingOccurrences(of: #"[\s\p{P}\p{S}]"#, with: "", options: .regularExpression)
        return ["未闭环", "阻塞", "建议", "下一步", "待办"].contains(normalized)
    }

    private static func isAlgorithmLabel(_ title: String) -> Bool {
        let normalized = title.replacingOccurrences(of: #"[\s\p{P}\p{S}]"#, with: "", options: .regularExpression)
        return normalized == "跨证据比较" || normalized.hasPrefix("行为模式") || normalized.hasPrefix("推断")
    }

    private static func isConcreteInsight(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let noise = ["证据不足", "暂无", "无明确", "跨证据", "行为模式"]
        return trimmed.count >= 8 && !noise.contains(where: trimmed.hasPrefix)
    }

    private static func isDuplicate(_ lhs: DailySummaryItem, _ rhs: DailySummaryItem) -> Bool {
        guard lhs.section == rhs.section else { return false }
        let leftTitle = normalizedKey(lhs.title)
        let rightTitle = normalizedKey(rhs.title)
        if leftTitle == rightTitle { return true }
        let left = normalizedKey("\(lhs.title)\(lhs.detail)")
        let right = normalizedKey("\(rhs.title)\(rhs.detail)")
        return min(left.count, right.count) >= 8 && (left.contains(right) || right.contains(left))
    }

    private static func normalizedKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
            .lowercased()
    }

    private static func section(for heading: String) -> DailySummarySection? {
        let compact = heading.replacingOccurrences(of: " ", with: "")
        if compact.contains("今天推进了什么") { return .progress }
        if compact.contains("接下来要处理") { return .actions }
        if compact.contains("值得留意") { return .insights }
        if compact.contains("主线") { return .headline }
        if compact.contains("真正完成") || compact == "进展" { return .progress }
        if compact.contains("尚未闭环") || compact.contains("未闭环") { return .openLoops }
        if compact.contains("发现") { return .insights }
        if compact.contains("待办") { return .todos }
        if compact.contains("14天") || compact.contains("十四天") { return .recent }
        if compact.contains("下一步") { return .nextActions }
        return nil
    }

    private static func isPlaceholder(_ text: String) -> Bool {
        ["未发现明确待办", "暂无需要主动打断你的建议", "无需要继续跟进的明确事项"].contains(text)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    private static func overlap(_ lhs: String, _ rhs: String) -> Int {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let left = Set(lhs.components(separatedBy: separators).filter { $0.count >= 2 })
        let right = Set(rhs.components(separatedBy: separators).filter { $0.count >= 2 })
        return left.intersection(right).count
    }

    private static func modelItem(
        _ value: DailySummaryModelItem,
        section: DailySummarySection,
        evidenceIDs: [UUID]
    ) -> DailySummaryItem? {
        let title = value.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = value.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        return DailySummaryItem(section: section, title: title, detail: detail, evidenceIDs: evidenceIDs)
    }
}

private struct DailySummaryModelResponse: Decodable {
    var headline: String?
    var progress: [DailySummaryModelItem]
    var actions: [DailySummaryModelItem]
    var insights: [DailySummaryModelItem]

    private enum CodingKeys: String, CodingKey { case headline, progress, actions, insights }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headline = try container.decodeIfPresent(String.self, forKey: .headline)
        progress = try container.decodeIfPresent([DailySummaryModelItem].self, forKey: .progress) ?? []
        actions = try container.decodeIfPresent([DailySummaryModelItem].self, forKey: .actions) ?? []
        insights = try container.decodeIfPresent([DailySummaryModelItem].self, forKey: .insights) ?? []
    }
}

private struct DailySummaryModelItem: Decodable {
    var title: String?
    var detail: String?
    var confidence: Double?
}

public struct DailySummary: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// 总结所对应的本地自然日，始终归一化为当天零点。
    public var day: Date
    public var createdAt: Date
    public var content: String
    public var sourceCaptureIDs: [UUID]
    /// 兼容旧存储键名；新代码应将其理解为统一行动事项，而不只是“待办”栏目。
    public var todos: [DailySummaryTodo]
    public var actions: [DailySummaryTodo] { todos }
    public var generationKind: DailySummaryGenerationKind
    /// 模型可用时 `content` 是主要展示；结构化简报用于本地兜底与后台状态整理。
    public var briefing: DailyBriefing?
    /// 结构化展示与条目级删除的数据源。Markdown 仅作为兼容与导出格式保留。
    public var items: [DailySummaryItem]

    public init(
        id: UUID = UUID(),
        day: Date,
        createdAt: Date = .now,
        content: String,
        sourceCaptureIDs: [UUID],
        todos: [DailySummaryTodo],
        generationKind: DailySummaryGenerationKind,
        briefing: DailyBriefing? = nil,
        items: [DailySummaryItem]? = nil
    ) {
        self.id = id
        self.day = Calendar.current.startOfDay(for: day)
        self.createdAt = createdAt
        self.content = content
        self.sourceCaptureIDs = sourceCaptureIDs
        self.todos = todos
        self.generationKind = generationKind
        self.briefing = briefing
        let persistedItems = items ?? []
        let resolvedItems = persistedItems.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DailySummaryItemParser.items(
                from: content,
                briefing: briefing,
                todos: todos,
                defaultEvidenceIDs: sourceCaptureIDs
            )
            : persistedItems
        self.items = DailySummaryItemParser.sanitized(resolvedItems)
    }

    private enum CodingKeys: String, CodingKey {
        case id, day, createdAt, content, sourceCaptureIDs, todos, generationKind, briefing, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        day = Calendar.current.startOfDay(for: try container.decode(Date.self, forKey: .day))
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        content = try container.decode(String.self, forKey: .content)
        sourceCaptureIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceCaptureIDs) ?? []
        todos = try container.decodeIfPresent([DailySummaryTodo].self, forKey: .todos) ?? []
        generationKind = try container.decodeIfPresent(DailySummaryGenerationKind.self, forKey: .generationKind) ?? .localFallback
        briefing = try container.decodeIfPresent(DailyBriefing.self, forKey: .briefing)
        let persistedItems = try container.decodeIfPresent([DailySummaryItem].self, forKey: .items) ?? []
        let decodedItems = persistedItems.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DailySummaryItemParser.items(
                from: content,
                briefing: briefing,
                todos: todos,
                defaultEvidenceIDs: sourceCaptureIDs
            )
            : persistedItems
        items = DailySummaryItemParser.sanitized(decodedItems)
    }
}

public struct DailySummarySettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var hour: Int
    public var minute: Int
    /// 默认关闭；只有用户在设置中明确打开后才请求通知权限。
    public var notifyWhenReady: Bool?

    public init(isEnabled: Bool = false, hour: Int = 0, minute: Int = 5, notifyWhenReady: Bool = false) {
        self.isEnabled = isEnabled
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.notifyWhenReady = notifyWhenReady
    }

    public func triggerDate(on day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

public struct DailySummaryGeneration: Sendable {
    public var content: String
    public var sourceCaptureIDs: [UUID]
    public var todos: [DailySummaryTodo]
    public var actions: [DailySummaryTodo] { todos }
    public var items: [DailySummaryItem]
    public var generationKind: DailySummaryGenerationKind
    public var briefing: DailyBriefing
    public var consolidation: IntelligenceConsolidation

    public init(
        content: String,
        sourceCaptureIDs: [UUID],
        todos: [DailySummaryTodo],
        items: [DailySummaryItem] = [],
        generationKind: DailySummaryGenerationKind,
        briefing: DailyBriefing,
        consolidation: IntelligenceConsolidation
    ) {
        self.content = content
        self.sourceCaptureIDs = sourceCaptureIDs
        self.todos = todos
        self.items = items
        self.generationKind = generationKind
        self.briefing = briefing
        self.consolidation = consolidation
    }
}

/// 为每日总结准备最小化的本地证据，并在云端模型不可用时提供可追溯的本地摘要。
/// 调用方必须自行确认用户已启用云端文本使用；本类型不会读取截图或写入持久化存储。
public struct DailySummaryGenerator: Sendable {
    public let maxRecords: Int
    public let maxCharactersPerRecord: Int
    public let maxRecentSummaries: Int
    public let maxCharactersPerRecentSummary: Int
    private let intelligenceEngine: PersonalIntelligenceEngine

    public init(
        maxRecords: Int = 36,
        maxCharactersPerRecord: Int = 720,
        maxRecentSummaries: Int = 14,
        maxCharactersPerRecentSummary: Int = 1_000,
        intelligenceEngine: PersonalIntelligenceEngine = PersonalIntelligenceEngine()
    ) {
        self.maxRecords = max(maxRecords, 1)
        self.maxCharactersPerRecord = max(maxCharactersPerRecord, 120)
        self.maxRecentSummaries = min(max(maxRecentSummaries, 1), 14)
        self.maxCharactersPerRecentSummary = max(maxCharactersPerRecentSummary, 240)
        self.intelligenceEngine = intelligenceEngine
    }

    public func sourceRecords(for day: Date, from captures: [CaptureRecord], calendar: Calendar = .current) -> [CaptureRecord] {
        let candidates = captures
            .filter { $0.eventTemplate != .dailyReview && calendar.isDate($0.createdAt, inSameDayAs: day) }
            .sorted { $0.createdAt < $1.createdAt }
        let selected: [CaptureRecord]
        if candidates.count <= maxRecords {
            selected = candidates
        } else {
            // 时间覆盖 + 重要性采样，避免旧实现只取上午前 24 条而丢失当天后半段。
            let anchorCount = min(6, maxRecords / 3)
            let anchors = Array(candidates.prefix(anchorCount)) + Array(candidates.suffix(anchorCount))
            let remaining = candidates
                .filter { candidate in !anchors.contains(where: { $0.id == candidate.id }) }
                .sorted { recordImportance($0) > recordImportance($1) }
                .prefix(maxRecords - anchors.count)
            selected = (anchors + remaining).sorted { $0.createdAt < $1.createdAt }
        }

        return selected.map { record in
            var minimized = record
            minimized.imageRelativePath = nil
            minimized.windowTitle = nil
            let rawExcerpt = String(record.ocrText.prefix(maxCharactersPerRecord))
            if let summary = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                minimized.ocrText = "本地摘要：\(String(summary.prefix(280)))\n原始摘录：\(rawExcerpt)"
            } else {
                minimized.ocrText = rawExcerpt
            }
            minimized.summary = nil
            return minimized
        }
    }

    /// 仅选择目标日前的十四个自然日中已保存的总结；当天和更早数据均不参与。
    public func recentSummaries(for day: Date, from summaries: [DailySummary], calendar: Calendar = .current) -> [DailySummary] {
        let targetDay = calendar.startOfDay(for: day)
        let earliestDay = calendar.date(byAdding: .day, value: -14, to: targetDay) ?? targetDay
        return summaries
            .filter { $0.day >= earliestDay && $0.day < targetDay }
            .sorted { $0.day > $1.day }
            .prefix(maxRecentSummaries)
            .map { summary in
                var minimized = summary
                minimized.content = String(summary.content.prefix(maxCharactersPerRecentSummary))
                return minimized
            }
    }

    public func todos(from records: [CaptureRecord]) -> [DailySummaryTodo] {
        let candidates = ReminderExtractor().candidates(from: records, existing: [])
        return candidates.map { candidate in
            let priority: DailySummaryTodoPriority = candidate.dueAt != nil || candidate.confidence >= 0.8 ? .high : .normal
            return DailySummaryTodo(
                id: candidate.id,
                title: candidate.title,
                detail: candidate.detail,
                status: candidate.status == .completed ? .completed : (candidate.status == .dismissed || candidate.status == .cancelled ? .ignored : .pending),
                dueAt: candidate.dueAt,
                reminderAt: candidate.scheduledAt,
                sourceCaptureIDs: candidate.sourceCaptureIDs,
                priority: priority,
                firstSeenAt: candidate.createdAt,
                updatedAt: candidate.updatedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority == .high }
            switch (lhs.dueAt, rhs.dueAt) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.title < rhs.title
            }
        }
    }

    public func generate(
        day: Date,
        from captures: [CaptureRecord],
        previousSummaries: [DailySummary] = [],
        existingEpisodes: [WorkEpisode] = [],
        previousProjects: [ProjectState] = [],
        existingMemories: [UserMemory] = [],
        previousInsights: [PersonalInsight] = [],
        feedback: [InsightFeedback] = [],
        existingRoutines: [LearnedRoutine] = [],
        responder: (any LLMResponding)? = nil,
        calendar: Calendar = .current
    ) async throws -> DailySummaryGeneration {
        let records = sourceRecords(for: day, from: captures, calendar: calendar)
        let originalDayRecords = captures.filter {
            $0.eventTemplate != .dailyReview && calendar.isDate($0.createdAt, inSameDayAs: day)
        }
        let priorityTodos = todos(from: originalDayRecords)
        let consolidation = intelligenceEngine.consolidate(
            day: day,
            records: captures,
            existingEpisodes: existingEpisodes,
            previousProjects: previousProjects,
            existingMemories: existingMemories,
            previousInsights: previousInsights,
            feedback: feedback,
            existingRoutines: existingRoutines,
            calendar: calendar
        )
        guard !records.isEmpty else {
            let content = emptyDaySummary(for: day)
            return DailySummaryGeneration(
                content: content,
                sourceCaptureIDs: [],
                todos: [],
                items: DailySummaryItemParser.items(from: content, defaultEvidenceIDs: []),
                generationKind: .localFallback,
                briefing: consolidation.briefing,
                consolidation: consolidation
            )
        }

        guard let responder else {
            let extractedItems = localItems(
                briefing: consolidation.briefing,
                todos: priorityTodos,
                defaultEvidenceIDs: records.map(\.id)
            )
            let actions = unifiedActions(from: extractedItems, ruleActions: priorityTodos, now: day)
            let items = replacingActionItems(in: extractedItems, with: actions)
            return DailySummaryGeneration(
                content: DailySummaryItemParser.markdown(from: items),
                sourceCaptureIDs: records.map(\.id),
                todos: actions,
                items: items,
                generationKind: .localFallback,
                briefing: consolidation.briefing,
                consolidation: consolidation
            )
        }

        let answer = try await responder.answer(to: LLMRequest(
            question: cloudPrompt(for: day, todos: priorityTodos),
            context: records,
            supplementaryContext: structuredContext(
                targetDay: day,
                activeProjectKeys: Set(consolidation.episodes.map(\.projectKey)),
                previousProjects: previousProjects,
                memories: consolidation.memories,
                calendar: calendar
            )
        ))
        let modelItems = DailySummaryItemParser.itemsFromModelResponse(
            answer.content,
            defaultEvidenceIDs: answer.citedCaptureIDs
        ) ?? DailySummaryItemParser.items(
            from: answer.content,
            defaultEvidenceIDs: answer.citedCaptureIDs
        )
        let fallbackItems = localItems(
            briefing: consolidation.briefing,
            todos: priorityTodos,
            defaultEvidenceIDs: records.map(\.id)
        )
        let extractedItems = mergedItems(modelItems: modelItems, fallbackItems: fallbackItems)
        let actions = unifiedActions(from: extractedItems, ruleActions: priorityTodos, now: day)
        let finalItems = replacingActionItems(in: extractedItems, with: actions)
        return DailySummaryGeneration(
            content: DailySummaryItemParser.markdown(from: finalItems),
            sourceCaptureIDs: answer.citedCaptureIDs,
            todos: actions,
            items: finalItems,
            generationKind: .cloud,
            briefing: consolidation.briefing,
            consolidation: consolidation
        )
    }

    public func localSummary(
        for day: Date,
        briefing: DailyBriefing,
        todos: [DailySummaryTodo],
        recentSummaries: [DailySummary]
    ) -> String {
        let items = localItems(briefing: briefing, todos: todos, defaultEvidenceIDs: [])
        return DailySummaryItemParser.markdown(from: items)
    }

    private func emptyDaySummary(for day: Date) -> String {
        "## 今天推进了什么\n\n- 当天没有可汇总的显式记录。"
    }

    private func localItems(
        briefing: DailyBriefing,
        todos: [DailySummaryTodo],
        defaultEvidenceIDs: [UUID]
    ) -> [DailySummaryItem] {
        var items: [DailySummaryItem] = []
        let headline = briefing.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !headline.isEmpty {
            items.append(DailySummaryItem(section: .progress, title: headline, evidenceIDs: defaultEvidenceIDs))
        }
        items.append(contentsOf: briefing.progress.map {
            DailySummaryItem(section: .progress, title: $0.title, detail: $0.detail, evidenceIDs: $0.evidenceIDs)
        })

        let activeTodos = todos.filter { $0.status == .pending || $0.status == .inProgress }
        items.append(contentsOf: activeTodos.map { todo in
            DailySummaryItem(section: .actions, title: todo.title, detail: todo.detail, evidenceIDs: todo.sourceCaptureIDs)
        })
        items.append(contentsOf: briefing.openLoops.map {
            DailySummaryItem(section: .actions, title: $0.title, detail: $0.detail, evidenceIDs: $0.evidenceIDs)
        })
        items.append(contentsOf: briefing.nextActions.map {
            DailySummaryItem(section: .actions, title: $0.title, detail: $0.detail, evidenceIDs: $0.evidenceIDs)
        })

        items.append(contentsOf: briefing.insights.compactMap { insight in
            guard insight.confidence >= 0.55 else { return nil }
            let title = insight.confidence < 0.75 && !insight.title.hasPrefix("可能")
                ? "可能：\(insight.title)"
                : insight.title
            let detail = [insight.detail, insight.recommendation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "；")
            return DailySummaryItem(section: .insights, title: title, detail: detail, evidenceIDs: insight.evidenceIDs)
        })
        return limited(DailySummaryItemParser.sanitized(items))
    }

    private func mergedItems(
        modelItems: [DailySummaryItem],
        fallbackItems: [DailySummaryItem]
    ) -> [DailySummaryItem] {
        let modelSections = Set(modelItems.map { $0.section.canonical })
        var merged = modelItems
        // 模型漏掉行动事项时仍保留本地明确提取结果；“值得留意”没有高价值内容时保持隐藏。
        merged.append(contentsOf: fallbackItems.filter { item in
            item.section == .actions || !modelSections.contains(item.section)
        })
        return limited(DailySummaryItemParser.sanitized(merged))
    }

    private func limited(_ items: [DailySummaryItem]) -> [DailySummaryItem] {
        DailySummarySection.displaySections.flatMap { section in
            let limit = section == .progress ? 4 : 3
            return Array(items.filter { $0.section == section }.prefix(limit))
        }
    }

    private func unifiedActions(
        from items: [DailySummaryItem],
        ruleActions: [DailySummaryTodo],
        now: Date
    ) -> [DailySummaryTodo] {
        var result = ruleActions.filter { $0.status == .pending || $0.status == .inProgress }
        for item in items where item.section == .actions {
            let itemKey = actionKey(item.title)
            if let index = result.firstIndex(where: { actionKey($0.title) == itemKey }) {
                if item.detail.count > result[index].detail.count { result[index].detail = item.detail }
                result[index].sourceCaptureIDs = Array(Set(result[index].sourceCaptureIDs + item.evidenceIDs))
                result[index].updatedAt = now
            } else {
                result.append(DailySummaryTodo(
                    title: item.title,
                    detail: item.detail,
                    status: .pending,
                    sourceCaptureIDs: item.evidenceIDs,
                    priority: result.isEmpty ? .high : .normal,
                    firstSeenAt: now,
                    updatedAt: now
                ))
            }
        }
        return Array(result.prefix(3))
    }

    private func actionKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
            .lowercased()
    }

    private func replacingActionItems(
        in items: [DailySummaryItem],
        with actions: [DailySummaryTodo]
    ) -> [DailySummaryItem] {
        let nonActions = items.filter { $0.section != .actions }
        let actionItems = actions.map { action in
            let timing = [
                action.dueAt.map { "截止：\($0.formatted(date: .abbreviated, time: .shortened))" },
                action.reminderAt.map { "提醒：\($0.formatted(date: .abbreviated, time: .shortened))" }
            ].compactMap { $0 }.joined(separator: "；")
            return DailySummaryItem(
                section: .actions,
                title: action.title,
                detail: [action.detail, timing].filter { !$0.isEmpty }.joined(separator: "；"),
                evidenceIDs: action.sourceCaptureIDs
            )
        }
        return limited(DailySummaryItemParser.sanitized(nonActions + actionItems))
    }

    private func structuredContext(
        targetDay: Date,
        activeProjectKeys: Set<String>,
        previousProjects: [ProjectState],
        memories: [UserMemory],
        calendar: Calendar
    ) -> String? {
        guard !previousProjects.isEmpty || !memories.isEmpty else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_Hans_CN")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let earliestDay = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: targetDay)) ?? targetDay
        let projects = previousProjects
            .filter { activeProjectKeys.contains($0.projectKey) }
            .filter { $0.lastActiveAt >= earliestDay }
            .filter { isUsableHistoricalProject($0) }
            .prefix(8)
            .map { project in
            "- \(project.displayName)（最近活动 \(dateFormatter.string(from: project.lastActiveAt))）：\(project.currentState)；已记录动作：\(project.nextAction ?? "无")"
        }
        let memoryLines = memories
            .filter { $0.status == .confirmed }
            .prefix(8)
            .map { "- \($0.kind.title)：\($0.content)" }
        return [
            "当天仍在推进项目的历史状态（只用于解释当天变化，不得直接当作当天事实或提醒）：\n\(projects.isEmpty ? "无" : projects.joined(separator: "\n"))",
            "后台长期记忆（只用于理解用户，不得直接写成当天进展或待办）：\n\(memoryLines.isEmpty ? "无" : memoryLines.joined(separator: "\n"))"
        ].joined(separator: "\n\n")
    }

    private func isUsableCarryOverTodo(_ todo: DailySummaryTodo) -> Bool {
        let title = todo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...100).contains(title.count) else { return false }
        let abstractDirections = ["产品方向", "改进方向", "设计理念", "愿景", "以系统流程为中心", "以用户为中心"]
        if todo.dueAt == nil, abstractDirections.contains(where: title.contains) { return false }
        return todo.dueAt != nil || !DailySummaryContentFormatter.validatedNextActions(from: [title], limit: 1).isEmpty
    }

    private func isUsableHistoricalProject(_ project: ProjectState) -> Bool {
        guard (2...42).contains(project.displayName.count),
              !project.projectKey.hasPrefix("app:"),
              !project.projectKey.hasPrefix("unresolved:") else { return false }
        let normalizedName = project.displayName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
            .lowercased()
        let tools = ["微信", "企业微信", "wechat", "wecom", "chrome", "safari", "xcode", "terminal", "zsh", "chatgpt", "claude", "codex", "localmcp"]
        if tools.contains(normalizedName) { return false }
        if normalizedName.range(of: #"^[a-f0-9]{6,12}[a-z]?$"#, options: .regularExpression) != nil { return false }
        let text = "\(project.displayName) \(project.currentState)"
        let noise = ["通讯录", "微盘", "工作台", "标签页", "200keeper", "×", "|S", "Q 搜索"]
        return noise.filter(text.contains).count < 2
    }

    private func cloudPrompt(for day: Date, todos: [DailySummaryTodo]) -> String {
        let date = day.formatted(.dateTime.year().month().day())
        let knownTodos: String
        if todos.isEmpty {
            knownTodos = "未从规则中识别出明确待办；请仅在证据确有待办、承诺、截止或回复事项时列出。"
        } else {
            knownTodos = todos.map { todo in
                let due = todo.dueAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "未推断时间"
                return "- \(todo.priority.title)：\(todo.title)（\(due)）"
            }.joined(separator: "\n")
        }
        return """
        请基于已提供的、仅属于 \(date) 的记忆证据，生成一份高密度的简体中文个人简报。不要按时间逐条复述操作，不能补充证据之外的事实。你的工作是从嘈杂 OCR 中恢复少量有价值的具体事情，而不是转录屏幕文字。

        只输出一个合法 JSON 对象，不要输出 Markdown、代码围栏或解释文字。结构必须是：
        {
          "headline": "一句话概括今天真正推进的具体事情",
          "progress": [{"title": "具体成果", "detail": "实际变化或可验证结果"}],
          "actions": [{"title": "对象明确的可执行动作", "detail": "状态、截止或判断完成的标准"}],
          "insights": [{"title": "具体的新规律、风险或决策线索", "detail": "为什么值得留意", "confidence": 0.0}]
        }

        页面最终只回答三个问题：今天推进了什么、接下来要处理什么、有什么值得留意。不要把“尚未闭环、待办、下一步、提醒、近14天”拆成并列分类；它们都是 action 的状态、优先级、通知方式或筛选条件。同一事项只能出现一次。actions 最多 3 条，将最值得先做的放在第一条；没有明确动作就返回空数组。

        应用名、工具名和网站名（例如微信、企业微信、Chrome、IDE、终端）只能作为证据来源，绝不能直接充当“主线”“进展”“尚未闭环”“发现”或行动建议的事项名称。每项结论必须落到可验证的具体事情，例如某个项目、功能、问题、交付物、决定或下一步动作；无法从证据中识别具体事情时，明确写“证据不足”，不要用工具名代替，也不要猜测。

        先做证据清洗：丢弃菜单、通讯录、标签页列表、搜索词列表、终端噪声、单独的 commit 哈希、截断乱码和重复截图；证据中出现非 \(date) 的旧日期时，不得把旧内容当作当天进展。只有“完成/合并/提交”却没有说明完成了什么，也不得列为进展。最多保留 3 条主线，每条用“具体事项 + 实际变化/结果 + 下一步”表达；多条证据指向同一事项时必须合并，禁止把互不相关的 OCR 片段拼成一个标题。

        insights 最多 3 项，只写跨记录比较后才成立且对用户有决策价值的判断；单条记录、网页标签、导航文字和模型回复不得直接当作用户事实。confidence 是仅供后台过滤的 0 到 1 数值，正文标题禁止出现“置信度”“跨证据比较”“行为模式”等算法术语；证据不足时返回空数组。

        actions 每条必须同时包含对象、动作和可判断的结果，例如“补充退款幂等测试并提交 PR”；禁止输出“今天”“明天”“继续”“推进”等单独时间词或泛化动词。不要从旧总结快照复制行动事项。

        总长度控制在 1,200 个汉字以内。

        规则识别到的待办线索（仍需以证据为准）：
        \(knownTodos)
        """
    }

    private func recordImportance(_ record: CaptureRecord) -> Double {
        let text = record.ocrText.lowercased()
        let cues = ["完成", "通过", "决定", "结论", "待办", "下一步", "阻塞", "失败", "merged", "passed"]
        var score = record.eventTemplate == .taskCommitment || record.eventTemplate == .documentMilestone ? 0.7 : 0.35
        if cues.contains(where: text.contains) { score += 0.25 }
        if record.windowTitle != nil { score += 0.05 }
        return min(score, 1)
    }
}
