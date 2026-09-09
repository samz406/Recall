import Foundation

public enum DailySummaryGenerationKind: String, Codable, Sendable {
    case cloud
    case localFallback
}

public enum DailySummaryTodoPriority: String, Codable, Sendable {
    case high
    case normal

    public var title: String {
        switch self {
        case .high: "优先处理"
        case .normal: "待办"
        }
    }
}

public struct DailySummaryTodo: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var dueAt: Date?
    public var sourceCaptureIDs: [UUID]
    public var priority: DailySummaryTodoPriority

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        dueAt: Date? = nil,
        sourceCaptureIDs: [UUID] = [],
        priority: DailySummaryTodoPriority
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueAt = dueAt
        self.sourceCaptureIDs = sourceCaptureIDs
        self.priority = priority
    }
}

public struct DailySummary: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// 总结所对应的本地自然日，始终归一化为当天零点。
    public var day: Date
    public var createdAt: Date
    public var content: String
    public var sourceCaptureIDs: [UUID]
    public var todos: [DailySummaryTodo]
    public var generationKind: DailySummaryGenerationKind
    /// 结构化简报是主要产品数据；`content` 仅保留 Markdown 兼容展示与导出。
    public var briefing: DailyBriefing?

    public init(
        id: UUID = UUID(),
        day: Date,
        createdAt: Date = .now,
        content: String,
        sourceCaptureIDs: [UUID],
        todos: [DailySummaryTodo],
        generationKind: DailySummaryGenerationKind,
        briefing: DailyBriefing? = nil
    ) {
        self.id = id
        self.day = Calendar.current.startOfDay(for: day)
        self.createdAt = createdAt
        self.content = content
        self.sourceCaptureIDs = sourceCaptureIDs
        self.todos = todos
        self.generationKind = generationKind
        self.briefing = briefing
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
    public var generationKind: DailySummaryGenerationKind
    public var briefing: DailyBriefing
    public var consolidation: IntelligenceConsolidation

    public init(
        content: String,
        sourceCaptureIDs: [UUID],
        todos: [DailySummaryTodo],
        generationKind: DailySummaryGenerationKind,
        briefing: DailyBriefing,
        consolidation: IntelligenceConsolidation
    ) {
        self.content = content
        self.sourceCaptureIDs = sourceCaptureIDs
        self.todos = todos
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
        maxRecords: Int = 24,
        maxCharactersPerRecord: Int = 900,
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
            minimized.ocrText = String(record.ocrText.prefix(maxCharactersPerRecord))
            minimized.summary = record.summary.map { String($0.prefix(260)) }
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
                dueAt: candidate.dueAt,
                sourceCaptureIDs: candidate.sourceCaptureIDs,
                priority: priority
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
        let priorityTodos = todos(from: records)
        let recentSummaries = recentSummaries(for: day, from: previousSummaries, calendar: calendar)
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
            return DailySummaryGeneration(
                content: emptyDaySummary(for: day, recentSummaries: recentSummaries),
                sourceCaptureIDs: [],
                todos: [],
                generationKind: .localFallback,
                briefing: consolidation.briefing,
                consolidation: consolidation
            )
        }

        guard let responder else {
            return DailySummaryGeneration(
                content: localSummary(for: day, briefing: consolidation.briefing, todos: priorityTodos, recentSummaries: recentSummaries),
                sourceCaptureIDs: records.map(\.id),
                todos: priorityTodos,
                generationKind: .localFallback,
                briefing: consolidation.briefing,
                consolidation: consolidation
            )
        }

        let answer = try await responder.answer(to: LLMRequest(
            question: cloudPrompt(for: day, todos: priorityTodos, hasRecentSummaries: !recentSummaries.isEmpty),
            context: records,
            supplementaryContext: structuredContext(consolidation: consolidation, recentSummaries: recentSummaries)
        ))
        return DailySummaryGeneration(
            content: answer.content,
            sourceCaptureIDs: answer.citedCaptureIDs,
            todos: priorityTodos,
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M 月 d 日"
        let progress = briefing.progress.isEmpty
            ? ["- 暂未识别出形成结果的关键进展。"]
            : briefing.progress.map { "- \($0.title)：\($0.detail)" }
        let loops = briefing.openLoops.isEmpty
            ? ["- 未发现有明确证据的未闭环事项。"]
            : briefing.openLoops.map { "- \($0.title)：\($0.detail)" }
        let insightLines = briefing.insights.isEmpty
            ? ["- 当前证据不足以形成有价值的跨记录判断。"]
            : briefing.insights.map { insight in
                let advice = insight.recommendation.map { "；建议：\($0)" } ?? ""
                return "- \(insight.title)：\(insight.detail)\(advice)（置信度 \(Int(insight.confidence * 100))%）"
            }
        let nextActions = briefing.nextActions.isEmpty
            ? ["- 暂无需要主动打断你的建议。"]
            : briefing.nextActions.map { "- \($0.title)：\($0.detail)" }
        let todoLines: [String]
        if todos.isEmpty {
            todoLines = ["- 未从当天记录中识别出待办或截止事项。"]
        } else {
            todoLines = todos.map { todo in
                let due = todo.dueAt.map { "；建议时间：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                return "- 【\(todo.priority.title)】\(todo.title)\(due)"
            }
        }
        return [
            "## \(formatter.string(from: day)) 个人简报",
            "",
            "### 今天的主线",
            briefing.headline,
            "",
            "### 真正完成的进展",
            progress.joined(separator: "\n"),
            "",
            "### 尚未闭环",
            loops.joined(separator: "\n"),
            "",
            "### Recall 的发现",
            insightLines.joined(separator: "\n"),
            "",
            "### 待办与提醒",
            todoLines.joined(separator: "\n"),
            "",
            "### 下一步",
            nextActions.joined(separator: "\n"),
            "",
            recentSummaryReview(recentSummaries)
        ].joined(separator: "\n")
    }

    private func emptyDaySummary(for day: Date, recentSummaries: [DailySummary]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M 月 d 日"
        return [
            "## \(formatter.string(from: day)) 个人简报",
            "",
            "当天没有可汇总的显式记录。",
            "",
            recentSummaryReview(recentSummaries)
        ].joined(separator: "\n")
    }

    private func recentSummaryReview(_ recentSummaries: [DailySummary]) -> String {
        guard !recentSummaries.isEmpty else {
            return "## 近 14 天提醒与建议\n\n- 近 14 天内尚无已保存的每日总结，暂不能形成跨周期提醒。"
        }
        var seenTitles: Set<String> = []
        let todos = recentSummaries
            .flatMap(\.todos)
            .filter { seenTitles.insert($0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority == .high }
                switch (lhs.dueAt, rhs.dueAt) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.title < rhs.title
                }
            }
        let focusLines: [String]
        if todos.isEmpty {
            focusLines = ["- 已回顾 \(recentSummaries.count) 份已保存总结，未提取到重复出现的明确待办。"]
        } else {
            focusLines = todos.prefix(6).map { todo in
                let due = todo.dueAt.map { "；建议时间：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
                return "- 【\(todo.priority.title)】\(todo.title)\(due)"
            }
        }
        return [
            "## 近 14 天提醒与建议",
            "",
            "### 值得关注",
            focusLines.joined(separator: "\n"),
            "",
            "### 行动建议",
            "- 优先确认带有明确截止时间或重复出现的事项，并在“提醒”中由你确认后创建系统通知。",
            "- 若某项连续多日仍未推进，将它拆成下一步可完成的小动作，并在下次记录中更新结果。"
        ].joined(separator: "\n")
    }

    private func structuredContext(consolidation: IntelligenceConsolidation, recentSummaries: [DailySummary]) -> String? {
        guard !consolidation.projectStates.isEmpty || !consolidation.memories.isEmpty || !recentSummaries.isEmpty else { return nil }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_Hans_CN")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let projects = consolidation.projectStates.prefix(8).map { project in
            "- \(project.displayName)：\(project.currentState)；下一步：\(project.nextAction ?? "未确认")"
        }
        let memories = consolidation.memories
            .filter { $0.status == .confirmed }
            .prefix(8)
            .map { "- \($0.kind.title)：\($0.content)" }
        let historicalTodos = recentSummaries.flatMap(\.todos).prefix(8).map { todo in
            "- \(todo.title)（\(todo.dueAt.map { dateFormatter.string(from: $0) } ?? "未指定时间")）"
        }
        return [
            "结构化项目状态（可用于比较变化，不能替代当天证据）：\n\(projects.isEmpty ? "无" : projects.joined(separator: "\n"))",
            "用户已确认的长期记忆：\n\(memories.isEmpty ? "无" : memories.joined(separator: "\n"))",
            "近 14 天未清理的待办线索：\n\(historicalTodos.isEmpty ? "无" : historicalTodos.joined(separator: "\n"))"
        ].joined(separator: "\n\n")
    }

    private func cloudPrompt(for day: Date, todos: [DailySummaryTodo], hasRecentSummaries: Bool) -> String {
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
        请基于已提供的、仅属于 \(date) 的记忆证据，生成一份高密度的简体中文“个人简报”。不要按时间逐条复述操作，不能补充证据之外的事实；行为模式必须标为推断并说明置信度。

        请严格使用以下 Markdown 小节：
        ## 今天的主线
        ## 真正完成的进展
        ## 尚未闭环
        ## Recall 的发现
        ## 待办与提醒
        ## 近14天提醒与建议
        ## 下一步

        “待办与提醒”必须最醒目：将有明确截止、回复、承诺或行动要求的内容放在最前，使用“【优先处理】”或“【待办】”前缀；若没有明确待办，写“未发现明确待办”。每项基于当天原始记忆证据的事实性结论都保留对应的 [数字] 来源标记。

        应用名、工具名和网站名（例如微信、企业微信、Chrome、IDE、终端）只能作为证据来源，绝不能直接充当“主线”“进展”“尚未闭环”“发现”或行动建议的事项名称。每项结论必须落到可验证的具体事情，例如某个项目、功能、问题、交付物、决定或下一步动作；无法从证据中识别具体事情时，明确写“证据不足”，不要用工具名代替，也不要猜测。

        “Recall 的发现”最多 3 项，只写跨记录比较后才成立且对用户有决策价值的判断；单条记录、网页标签、导航文字和模型回复不得直接当作用户事实。标题必须描述具体事情或行为模式，禁止使用“今天的主要精力在某应用”一类结论。“近14天提醒与建议”只参考附带的结构化项目状态、已确认用户记忆和待办，不对历史 Markdown 总结再次摘要。\(hasRecentSummaries ? "" : "当前没有可用的近14天历史待办，应明确说明这一点。")

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
