import Foundation

/// 将离散截图/OCR 证据整理为工作片段、项目状态、用户记忆与有限数量的高价值洞察。
/// 所有推断均保留证据 ID 和置信度；本引擎不读取截图、不联网，也不执行外部动作。
public struct PersonalIntelligenceEngine: Sendable {
    public let episodeGap: TimeInterval
    public let maximumInsightsPerDay: Int
    public let minimumRoutineDays: Int

    public init(
        episodeGap: TimeInterval = 55 * 60,
        maximumInsightsPerDay: Int = 3,
        minimumRoutineDays: Int = 3
    ) {
        self.episodeGap = max(episodeGap, 5 * 60)
        self.maximumInsightsPerDay = max(maximumInsightsPerDay, 1)
        self.minimumRoutineDays = max(minimumRoutineDays, 2)
    }

    public func consolidate(
        day: Date,
        records: [CaptureRecord],
        existingEpisodes: [WorkEpisode] = [],
        previousProjects: [ProjectState] = [],
        existingMemories: [UserMemory] = [],
        previousInsights: [PersonalInsight] = [],
        feedback: [InsightFeedback] = [],
        existingRoutines: [LearnedRoutine] = [],
        calendar: Calendar = .current
    ) -> IntelligenceConsolidation {
        let targetRecords = records
            .filter { $0.eventTemplate != .dailyReview && calendar.isDate($0.createdAt, inSameDayAs: day) }
            .sorted { $0.createdAt < $1.createdAt }
        let episodes = buildEpisodes(day: day, records: targetRecords, calendar: calendar)
        let concreteEpisodes = episodes.filter(isConcreteWork)
        let projects = mergeProjectStates(
            previousProjects.filter { isConcreteProject(key: $0.projectKey, name: $0.displayName) },
            with: concreteEpisodes
        )
        let memories = mergeMemories(existingMemories, with: memoryCandidates(from: targetRecords))
        let insights = makeInsights(
            day: day,
            episodes: concreteEpisodes,
            projects: projects,
            previousInsights: previousInsights,
            feedback: feedback,
            calendar: calendar
        )
        let routines = makeRoutines(
            episodes: existingEpisodes.filter { !calendar.isDate($0.day, inSameDayAs: day) && isConcreteWork($0) } + concreteEpisodes,
            existing: existingRoutines,
            calendar: calendar
        )
        let newMemoryKeys = Set(memoryCandidates(from: targetRecords).map(\.key))
        let briefing = makeBriefing(
            episodes: concreteEpisodes,
            projects: projects,
            insights: insights,
            memoryCandidates: memories.filter { newMemoryKeys.contains($0.key) && $0.status == .proposed },
            routines: routines,
            calendar: calendar
        )
        return IntelligenceConsolidation(
            episodes: episodes,
            projectStates: projects,
            memories: memories,
            insights: insights,
            routines: routines,
            briefing: briefing
        )
    }

    public func buildEpisodes(day: Date, records: [CaptureRecord], calendar: Calendar = .current) -> [WorkEpisode] {
        let ordered = records
            .filter { $0.eventTemplate != .dailyReview && calendar.isDate($0.createdAt, inSameDayAs: day) }
            .sorted { $0.createdAt < $1.createdAt }
        guard !ordered.isEmpty else { return [] }

        var buckets: [EpisodeBucket] = []
        for record in ordered {
            let identity = projectIdentity(for: record)
            if let lastIndex = buckets.indices.last,
               buckets[lastIndex].projectKey == identity.key,
               record.createdAt.timeIntervalSince(buckets[lastIndex].endedAt) <= episodeGap {
                buckets[lastIndex].records.append(record)
                buckets[lastIndex].endedAt = record.createdAt
            } else {
                buckets.append(EpisodeBucket(
                    projectKey: identity.key,
                    projectName: identity.name,
                    startedAt: record.createdAt,
                    endedAt: record.createdAt,
                    records: [record]
                ))
            }
        }
        return buckets.map { episode(from: $0, day: day, calendar: calendar) }
    }

    private func episode(from bucket: EpisodeBucket, day: Date, calendar: Calendar) -> WorkEpisode {
        let ranked = bucket.records.sorted { recordSignal($0) > recordSignal($1) }
        let representative = ranked.first ?? bucket.records[0]
        let action = meaningfulExcerpt(from: representative)
        let combined = bucket.records.map(\.ocrText).joined(separator: "\n")
        let status = episodeStatus(from: combined)
        let outcome = [.completed, .progressed].contains(status) ? outcomeExcerpt(from: bucket.records) : nil
        let nextAction = extractNextAction(from: bucket.records)
        let sourceApps = Array(Set(bucket.records.compactMap(\.sourceAppName))).sorted()
        let importance = min(1, bucket.records.map(recordSignal).max()! + min(Double(bucket.records.count - 1) * 0.05, 0.2))
        let confidence = min(0.92, 0.58 + (bucket.records.count > 1 ? 0.12 : 0) + (bucket.projectKey.hasPrefix("unresolved:") ? 0 : 0.1))
        let statusText: String
        switch status {
        case .completed: statusText = "完成"
        case .progressed: statusText = "推进"
        case .pending: statusText = "待处理"
        case .blocked: statusText = "遇到阻塞"
        case .explored: statusText = "探索"
        }
        return WorkEpisode(
            day: calendar.startOfDay(for: day),
            startedAt: bucket.startedAt,
            endedAt: bucket.endedAt,
            projectKey: bucket.projectKey,
            projectName: bucket.projectName,
            title: "\(statusText) · \(bucket.projectName)",
            intent: inferredIntent(from: representative, projectName: bucket.projectName),
            action: action,
            outcome: outcome,
            nextAction: nextAction,
            status: status,
            importance: importance,
            confidence: confidence,
            sourceApps: sourceApps,
            evidenceIDs: bucket.records.map(\.id)
        )
    }

    private func mergeProjectStates(_ previous: [ProjectState], with episodes: [WorkEpisode]) -> [ProjectState] {
        var states = Dictionary(uniqueKeysWithValues: previous.map { ($0.projectKey, $0) })
        let grouped = Dictionary(grouping: episodes, by: \.projectKey)
        for (key, values) in grouped {
            guard let latest = values.max(by: { $0.endedAt < $1.endedAt }) else { continue }
            let existing = states[key]
            let completed = latest.status == .completed
            let blockers = values
                .filter { $0.status == .blocked }
                .map(\.action)
                .uniqued()
                .prefix(3)
            states[key] = ProjectState(
                projectKey: key,
                displayName: latest.projectName,
                goal: existing?.goal,
                currentState: latest.outcome ?? latest.action,
                nextAction: completed ? nil : (latest.nextAction ?? existing?.nextAction),
                blockers: Array(blockers),
                evidenceIDs: Array((existing?.evidenceIDs ?? []) + values.flatMap(\.evidenceIDs)).suffix(24),
                confidence: max(existing?.confidence ?? 0, latest.confidence),
                lastActiveAt: latest.endedAt,
                updatedAt: .now
            )
        }
        return states.values.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    private func makeInsights(
        day: Date,
        episodes: [WorkEpisode],
        projects: [ProjectState],
        previousInsights: [PersonalInsight],
        feedback: [InsightFeedback],
        calendar: Calendar
    ) -> [PersonalInsight] {
        guard !episodes.isEmpty else { return [] }
        let evidence = episodes.flatMap(\.evidenceIDs).uniqued()
        let distinctProjects = Set(episodes.map(\.projectKey))
        let topProjects = Dictionary(grouping: episodes, by: \.projectKey)
            .map { key, values in
                (key: key, name: values[0].projectName, score: values.reduce(0) { $0 + $1.importance })
            }
            .sorted { $0.score > $1.score }
        var candidates: [PersonalInsight] = []

        if let first = topProjects.first,
           episodes.filter({ $0.projectKey == first.key }).flatMap(\.evidenceIDs).uniqued().count >= 2 {
            let secondary = topProjects.dropFirst().first.map { "，其次是 \($0.name)" } ?? ""
            candidates.append(PersonalInsight(
                day: day,
                kind: .focus,
                title: "今天反复推进：\(first.name)",
                detail: "多条记录都指向 \(first.name)\(secondary)，这是基于记录密度的判断，不代表精确工时。",
                recommendation: nil,
                confidence: min(0.92, 0.65 + Double(episodes.filter { $0.projectKey == first.key }.count) * 0.06),
                impact: 0.62,
                novelty: novelty(of: .focus, comparedWith: previousInsights),
                evidenceIDs: episodes.filter { $0.projectKey == first.key }.flatMap(\.evidenceIDs).uniqued()
            ))
        }

        if distinctProjects.count >= 4 || episodes.count >= 7 {
            candidates.append(PersonalInsight(
                day: day,
                kind: .contextSwitching,
                title: "今天的上下文切换偏多",
                detail: "记录涉及 \(distinctProjects.count) 条工作主线并形成 \(episodes.count) 个工作片段，这通常会增加重新进入任务的成本。该结论是行为推断，不是确定事实。",
                recommendation: "明天先关闭最重要的一项未完成工作，再开启新的工作主线。",
                confidence: min(0.9, 0.55 + Double(distinctProjects.count) * 0.06),
                impact: 0.86,
                novelty: novelty(of: .contextSwitching, comparedWith: previousInsights),
                evidenceIDs: evidence
            ))
        }

        let completed = episodes.filter { $0.status == .completed }
        if !completed.isEmpty {
            candidates.append(PersonalInsight(
                day: day,
                kind: .completion,
                title: "今天形成了 \(completed.count) 个可验证结果",
                detail: completed.prefix(3).map { $0.outcome ?? $0.action }.joined(separator: "；"),
                recommendation: "优先把已完成结果沉淀为可复用资产或明确交付。",
                confidence: 0.82,
                impact: 0.72,
                novelty: novelty(of: .completion, comparedWith: previousInsights),
                evidenceIDs: completed.flatMap(\.evidenceIDs).uniqued()
            ))
        }

        let activeKeys = Set(episodes.map(\.projectKey))
        let stalled = projects.filter {
            !activeKeys.contains($0.projectKey) &&
            $0.nextAction != nil &&
            day.timeIntervalSince($0.lastActiveAt) >= 3 * 86_400
        }
        if let project = stalled.first {
            candidates.append(PersonalInsight(
                day: day,
                kind: .stalledWork,
                title: "\(project.displayName) 已连续多日没有新进展",
                detail: "该项目仍保留下一步，但最近三天没有新的可追溯记录。",
                recommendation: project.nextAction.map { "决定继续、延期或关闭；若继续，下一步是：\($0)" },
                confidence: 0.76,
                impact: 0.8,
                novelty: novelty(of: .stalledWork, comparedWith: previousInsights),
                evidenceIDs: project.evidenceIDs
            ))
        }

        let rejectedKinds = Dictionary(grouping: feedback.filter { [.inaccurate, .dismissed].contains($0.rating) }, by: \.insightKind)
        return candidates
            .filter { (rejectedKinds[$0.kind]?.count ?? 0) < 2 }
            .map { insight in
                var adjusted = insight
                if feedback.contains(where: { $0.insightKind == insight.kind && $0.rating == .partiallyAccurate }) {
                    adjusted.confidence *= 0.82
                }
                return adjusted
            }
            .sorted { $0.interventionScore > $1.interventionScore }
            .prefix(maximumInsightsPerDay)
            .map { $0 }
    }

    private func makeRoutines(episodes: [WorkEpisode], existing: [LearnedRoutine], calendar: Calendar) -> [LearnedRoutine] {
        var routines = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
        let byProject = Dictionary(grouping: episodes, by: \.projectKey)
        for (key, values) in byProject {
            let distinctDays = Set(values.map { calendar.startOfDay(for: $0.day) })
            guard distinctDays.count >= minimumRoutineDays, let latest = values.max(by: { $0.endedAt < $1.endedAt }) else { continue }
            let routineKey = "project-close:\(key)"
            let previous = routines[routineKey]
            routines[routineKey] = LearnedRoutine(
                id: previous?.id ?? UUID(),
                key: routineKey,
                title: "为 \(latest.projectName) 建立收工检查",
                trigger: "当天结束且处理过 \(latest.projectName) 时",
                suggestedAction: "检查结果、未闭环事项和下一步，并只在你确认后创建提醒。",
                confidence: min(0.92, 0.58 + Double(distinctDays.count) * 0.08),
                evidenceCount: values.count,
                status: previous?.status ?? .proposed,
                evidenceIDs: Array(values.flatMap(\.evidenceIDs).uniqued().suffix(24)),
                updatedAt: .now
            )
        }
        return routines.values.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status == .proposed }
            return lhs.confidence > rhs.confidence
        }
    }

    private func memoryCandidates(from records: [CaptureRecord]) -> [UserMemory] {
        let cues: [(UserMemoryKind, [String])] = [
            (.preference, ["我喜欢", "我更喜欢", "我不喜欢", "不要", "偏好"]),
            (.goal, ["我的目标", "目标是", "我想要", "我希望"]),
            (.constraint, ["必须", "不能", "不要再", "限制"]),
            (.habit, ["我通常", "我习惯", "每天", "每周"]),
            (.workflowLesson, ["以后遇到", "下次", "流程是", "老规矩"])
        ]
        var result: [UserMemory] = []
        for record in records {
            let sentences = record.ocrText
                .components(separatedBy: CharacterSet(charactersIn: "。！？!?\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 220 }
            for sentence in sentences {
                guard let match = cues.first(where: { _, words in words.contains(where: sentence.contains) }) else { continue }
                let normalized = sentence.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                let key = "\(match.0.rawValue):\(String(normalized.prefix(72)))"
                result.append(UserMemory(
                    key: key,
                    kind: match.0,
                    content: sentence,
                    confidence: record.eventTemplate == .taskCommitment ? 0.84 : 0.68,
                    evidenceIDs: [record.id]
                ))
            }
        }
        return Dictionary(grouping: result, by: \.key).compactMap { _, values in
            guard var first = values.first else { return nil }
            first.evidenceIDs = values.flatMap(\.evidenceIDs).uniqued()
            first.confidence = min(0.9, first.confidence + Double(values.count - 1) * 0.08)
            return first
        }
    }

    private func mergeMemories(_ existing: [UserMemory], with candidates: [UserMemory]) -> [UserMemory] {
        var memories = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
        for candidate in candidates {
            guard var previous = memories[candidate.key] else {
                memories[candidate.key] = candidate
                continue
            }
            guard previous.status != .rejected else { continue }
            previous.evidenceIDs = (previous.evidenceIDs + candidate.evidenceIDs).uniqued()
            previous.confidence = min(0.95, max(previous.confidence, candidate.confidence) + 0.04)
            previous.updatedAt = .now
            memories[candidate.key] = previous
        }
        return memories.values.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status == .proposed }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func makeBriefing(
        episodes: [WorkEpisode],
        projects: [ProjectState],
        insights: [PersonalInsight],
        memoryCandidates: [UserMemory],
        routines: [LearnedRoutine],
        calendar: Calendar
    ) -> DailyBriefing {
        guard !episodes.isEmpty else {
            return DailyBriefing(
                headline: "当天没有可用于分析的显式记录。",
                progress: [], openLoops: [], insights: [], nextActions: [],
                memoryCandidates: [], routineCandidates: [], episodeIDs: []
            )
        }
        let ranked = episodes.filter(isConcreteWork).sorted { $0.importance > $1.importance }
        guard !ranked.isEmpty else {
            return DailyBriefing(
                headline: "当天记录尚不足以识别具体事项；应用与网站仅作为证据来源。",
                progress: [], openLoops: [], insights: [], nextActions: [],
                memoryCandidates: Array(memoryCandidates.prefix(4)),
                routineCandidates: [], episodeIDs: episodes.map(\.id)
            )
        }
        let projectNames = ranked.map(\.projectName).uniqued()
        let headline: String
        if projectNames.count == 1 {
            headline = "今天主要推进：\(projectNames[0])。"
        } else {
            headline = "今天主要推进：\(projectNames[0])；同时处理：\(projectNames.dropFirst().prefix(2).joined(separator: "、"))。"
        }
        var seenProgress: Set<String> = []
        let progress = ranked
            .filter { [.completed, .progressed].contains($0.status) }
            .filter { seenProgress.insert($0.projectKey).inserted }
            .prefix(4)
            .map { BriefingItem(title: $0.title, detail: $0.outcome ?? $0.action, confidence: $0.confidence, evidenceIDs: $0.evidenceIDs) }
        var seenOpenLoops: Set<String> = []
        let openLoops = ranked
            .filter { [.pending, .blocked].contains($0.status) || $0.nextAction != nil }
            .filter { episode in
                let key = normalizedKey(episode.nextAction ?? episode.projectName)
                return seenOpenLoops.insert(key).inserted
            }
            .prefix(4)
            .map { episode in
                BriefingItem(
                    title: episode.status == .blocked ? "阻塞 · \(episode.projectName)" : "未闭环 · \(episode.projectName)",
                    detail: episode.nextAction ?? episode.action,
                    confidence: episode.confidence,
                    evidenceIDs: episode.evidenceIDs
                )
            }
        var nextActions = Array(openLoops.prefix(2))
        for insight in insights where nextActions.count < 3 {
            guard let recommendation = insight.recommendation else { continue }
            nextActions.append(BriefingItem(
                title: "建议 · \(insight.kind.title)",
                detail: recommendation,
                confidence: insight.confidence,
                evidenceIDs: insight.evidenceIDs
            ))
        }
        if nextActions.isEmpty, let first = ranked.first {
            nextActions = [BriefingItem(
                title: "沉淀今天的结果",
                detail: "确认 \(first.projectName) 的最终结果，并明确下一次从哪里继续。",
                confidence: 0.62,
                evidenceIDs: first.evidenceIDs
            )]
        }
        let activeProjectKeys = Set(ranked.map(\.projectKey))
        for routine in routines where routine.status == .enabled && nextActions.count < 3 {
            let projectKey = routine.key.replacingOccurrences(of: "project-close:", with: "")
            guard activeProjectKeys.contains(projectKey) else { continue }
            nextActions.append(BriefingItem(
                title: routine.title,
                detail: routine.suggestedAction,
                confidence: routine.confidence,
                evidenceIDs: routine.evidenceIDs
            ))
        }
        return DailyBriefing(
            headline: headline,
            progress: Array(progress),
            openLoops: Array(openLoops),
            insights: insights,
            nextActions: nextActions,
            memoryCandidates: Array(memoryCandidates.prefix(4)),
            routineCandidates: Array(routines.filter { $0.status == .proposed }.prefix(2)),
            episodeIDs: ranked.map(\.id)
        )
    }

    private func projectIdentity(for record: CaptureRecord) -> (key: String, name: String) {
        let searchable = [record.windowTitle, record.summary, record.ocrText].compactMap { $0 }.joined(separator: " ")
        if let repository = firstMatch(in: searchable, pattern: #"github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"#, group: 1) {
            let name = repository.split(separator: "/").last.map(String.init) ?? repository
            return ("repo:\(repository.lowercased())", name)
        }
        if let explicit = firstMatch(in: searchable, pattern: #"(?:项目|仓库|repository|repo)[\s:：]+([A-Za-z0-9_.\-/]{2,48})"#, group: 1) {
            let cleaned = explicit.trimmingCharacters(in: CharacterSet(charactersIn: "/.,，。"))
            return ("project:\(cleaned.lowercased())", cleaned)
        }
        if let subject = concreteWorkSubject(for: record) {
            return ("topic:\(normalizedKey(subject))", subject)
        }
        if let title = record.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let candidate = title.components(separatedBy: " - ").first?.components(separatedBy: " · ").first ?? title
            let sourceApp = record.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if candidate.count >= 2,
               candidate.lowercased() != sourceApp,
               !["new tab", "新标签页", "recall"].contains(candidate.lowercased()),
               !isToolOrContainerName(candidate) {
                return ("window:\(candidate.lowercased())", String(candidate.prefix(56)))
            }
        }
        return ("unresolved:\(record.id.uuidString.lowercased())", "具体事项证据不足")
    }

    private func concreteWorkSubject(for record: CaptureRecord) -> String? {
        let text = record.summary?.nonEmpty ?? record.ocrText
        let patterns = [
            #"(?:今天|昨日|昨天|上午|下午|晚上)?\s*(?:已经|已|正在|继续|计划|准备|需要)?\s*(?:完成|推进|修复|优化|重构|开发|实现|排查|分析|设计|验证|测试|提交|发布|处理|讨论|调研|编写|接入|迁移|解决)[了\s:：·-]*([^，。；！？!?\n]{3,56})"#,
            #"(?:待办|下一步|后续)[\s:：·-]+([^，。；！？!?\n]{3,56})"#
        ]
        for pattern in patterns {
            guard let match = firstMatch(in: text, pattern: pattern, group: 1),
                  let subject = cleanedSubject(match, record: record) else { continue }
            return subject
        }
        return nil
    }

    private func cleanedSubject(_ value: String, record: CaptureRecord) -> String? {
        var subject = value
            .replacingOccurrences(of: #"^[\s\"“”'‘’]*(?:今天|明天|昨日|昨天|本周|下周)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n:：·-—,，.。;；!?！？\"“”'‘’"))
        subject = String(subject.prefix(56))
        guard subject.count >= 3 else { return nil }
        let normalized = normalizedKey(subject)
        let sourceApp = normalizedKey(record.sourceAppName ?? "")
        let windowTitle = normalizedKey(record.windowTitle ?? "")
        guard normalized != sourceApp, normalized != windowTitle else { return nil }
        let generic = ["待办", "工作", "任务", "测试", "验证窗口", "聊天", "新标签页"]
        guard !generic.contains(where: { normalized == normalizedKey($0) }) else { return nil }
        return subject
    }

    private func isConcreteWork(_ episode: WorkEpisode) -> Bool {
        isConcreteProject(key: episode.projectKey, name: episode.projectName)
    }

    private func isConcreteProject(key: String, name: String) -> Bool {
        !key.hasPrefix("app:") &&
        !key.hasPrefix("unresolved:") &&
        name != "未分类工作" &&
        name != "具体事项证据不足" &&
        !isToolOrContainerName(name)
    }

    private func isToolOrContainerName(_ value: String) -> Bool {
        let normalized = normalizedKey(value)
        let tools = [
            "微信", "企业微信", "wechat", "wecom", "chrome", "googlechrome", "safari", "edge", "firefox",
            "xcode", "intellijidea", "vscode", "visualstudiocode", "terminal", "终端", "iterm", "zsh",
            "chatgpt", "claude", "codex", "gemini", "perplexity", "localmcp"
        ]
        return tools.contains(normalized)
    }

    private func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
            .lowercased()
    }

    private func inferredIntent(from record: CaptureRecord, projectName: String) -> String {
        switch record.eventTemplate {
        case .webResearchClip: return "研究与理解 \(projectName)"
        case .meetingSession: return "围绕 \(projectName) 对齐信息"
        case .taskCommitment: return "为 \(projectName) 明确待办"
        case .documentMilestone: return "推进 \(projectName) 的文档或交付物"
        case .taskTransition: return "切换并复盘 \(projectName)"
        default: return "推进或了解 \(projectName)"
        }
    }

    private func episodeStatus(from text: String) -> WorkEpisodeStatus {
        let normalized = text.lowercased()
        if containsAny(normalized, ["失败", "报错", "阻塞", "卡住", "无法", "error", "failed"]) { return .blocked }
        if containsAny(normalized, ["已完成", "完成了", "测试通过", "构建通过", "已合并", "上线", "done", "passed", "merged"]) { return .completed }
        if containsAny(normalized, ["待办", "下一步", "需要处理", "明天", "后续", "todo", "follow up"]) { return .pending }
        if containsAny(normalized, ["实现", "修改", "重构", "推进", "新增", "修复", "优化", "develop", "fix", "refactor"]) { return .progressed }
        return .explored
    }

    private func outcomeExcerpt(from records: [CaptureRecord]) -> String? {
        let cues = ["已完成", "完成了", "测试通过", "构建通过", "已合并", "上线", "done", "passed", "merged", "实现", "修复"]
        return records.reversed().compactMap { record in
            sentences(in: record.ocrText).first(where: { sentence in containsAny(sentence.lowercased(), cues) })
        }.first.map { String($0.prefix(180)) }
    }

    private func extractNextAction(from records: [CaptureRecord]) -> String? {
        let cues = ["待办", "下一步", "需要", "明天", "后续", "回复", "提交", "推送", "todo", "follow up"]
        return records.reversed().compactMap { record in
            sentences(in: record.ocrText).first(where: { sentence in containsAny(sentence.lowercased(), cues) })
        }.first.map { String($0.prefix(180)) }
    }

    private func meaningfulExcerpt(from record: CaptureRecord) -> String {
        let source = record.summary?.nonEmpty ?? record.ocrText
        let clean = source.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(220))
    }

    private func recordSignal(_ record: CaptureRecord) -> Double {
        let text = record.ocrText.lowercased()
        var score = 0.34
        if record.eventTemplate == .taskCommitment || record.eventTemplate == .documentMilestone { score += 0.18 }
        if containsAny(text, ["完成", "通过", "决定", "结论", "待办", "下一步", "阻塞", "失败", "merged", "passed"]) { score += 0.24 }
        if text.count > 80 { score += 0.08 }
        if record.windowTitle?.nonEmpty != nil { score += 0.06 }
        return min(score, 1)
    }

    private func novelty(of kind: PersonalInsightKind, comparedWith previous: [PersonalInsight]) -> Double {
        let repetitions = previous.filter { $0.kind == kind }.count
        return max(0.35, 1 - Double(repetitions) * 0.12)
    }

    private func sentences(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "。！？!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func containsAny(_ text: String, _ cues: [String]) -> Bool {
        cues.contains { text.contains($0) }
    }

    private func firstMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              group < match.numberOfRanges,
              let swiftRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[swiftRange])
    }
}

private struct EpisodeBucket {
    var projectKey: String
    var projectName: String
    var startedAt: Date
    var endedAt: Date
    var records: [CaptureRecord]
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
