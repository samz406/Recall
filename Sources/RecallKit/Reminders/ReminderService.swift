import Foundation
// Keep notification objects confined to LocalNotificationScheduler on MainActor.
// The Xcode 16 SDK has not yet annotated these Objective-C types for concurrency.
@preconcurrency import UserNotifications

public struct ReminderExtractor: Sendable {
    public static let version = 3
    public init() {}

    public func candidates(
        from captures: [CaptureRecord],
        existing: [ReminderCandidate],
        now: Date = .now,
        resolutionCaptures: [CaptureRecord] = [],
        learningProfile: ReminderLearningProfile = ReminderLearningProfile()
    ) -> [ReminderCandidate] {
        guard !captures.isEmpty else { return [] }
        let allowed = Set((captures + resolutionCaptures).map(\.id))
        let captures = captures.map { $0.scopingUnderstanding(to: allowed) }
        let resolutionCaptures = resolutionCaptures.map { $0.scopingUnderstanding(to: allowed) }
        var result: [ReminderCandidate] = []
        let blockers = BlockIndex(existing, extractor: self)
        let resolutions = (captures + resolutionCaptures).flatMap { capture in
            RecordedText.segments(in: capture).compactMap { segment -> Resolution? in
                guard segment.speaker == .user, isResolution(segment.text) else { return nil }
                return Resolution(captureID: capture.id, createdAt: capture.createdAt, segment: segment)
            }
        }

        for capture in captures.sorted(by: { $0.createdAt > $1.createdAt }) where !capture.ocrText.isEmpty && capture.memoryDirective == nil && learningProfile.permitsReminderDiscovery(from: capture) {
            if let understood = capture.understanding {
                for fact in understood.facts where fact.isUserAction {
                    let closed = (captures + resolutionCaptures).contains { later in
                        later.createdAt >= capture.createdAt && later.understanding?.facts.contains(where: {
                            $0.actor == .user && [.completed, .cancelled].contains($0.status)
                                && fingerprint($0.subject) == fingerprint(fact.subject)
                        }) == true
                    }
                    guard !closed else { continue }
                    let draft = ReminderCandidate(title: fact.subject, detail: fact.readableDetail,
                        dueAt: fact.explicitDeadline, sourceCaptureIDs: fact.sourceIDs, confidence: 0.8,
                        createdAt: capture.createdAt, origin: .discovered, semanticKey: fingerprint(fact.subject))
                    guard !learningProfile.suppressesHistory(draft, now: now), !blockers.blocks(draft, now: now) else { continue }
                    if let i = result.firstIndex(where: { sameOccurrence($0, draft) }) {
                        result[i].sourceCaptureIDs = Array(Set(result[i].sourceCaptureIDs + draft.sourceCaptureIDs))
                    } else { result.append(draft) }
                }
                continue
            }
            for segment in RecordedText.segments(in: capture) {
                guard let analysis = analyze(segment, base: capture.createdAt) else { continue }
                let semanticKey = fingerprint(analysis.title)
                let recurrence = inferredRecurrence(in: segment.text)
                if recurrence == .none, resolutions.contains(where: {
                    let isLater = $0.captureID == capture.id
                        ? $0.segment.ordinal > segment.ordinal
                        : $0.createdAt > capture.createdAt
                    return isLater && resolves(title: analysis.title, with: $0.segment.text)
                }) { continue }
                let draft = ReminderCandidate(
                    title: analysis.title,
                    detail: detail(for: capture, segment: segment.text, reason: analysis.reason),
                    dueAt: analysis.dueAt,
                    sourceCaptureIDs: [capture.id],
                    confidence: analysis.confidence,
                    createdAt: capture.createdAt,
                    updatedAt: capture.createdAt,
                    origin: .discovered,
                    recurrence: recurrence,
                    semanticKey: semanticKey
                )
                guard !learningProfile.suppressesHistory(draft, now: now), !blockers.blocks(draft, now: now) else { continue }

                if let index = result.firstIndex(where: { sameOccurrence($0, draft) }) {
                    if !result[index].sourceCaptureIDs.contains(capture.id) {
                        result[index].sourceCaptureIDs.append(capture.id)
                    }
                    result[index].confidence = max(result[index].confidence, analysis.confidence)
                    if result[index].dueAt == nil {
                        result[index].dueAt = analysis.dueAt
                    }
                    result[index].updatedAt = max(result[index].updatedAt, capture.createdAt)
                    continue
                }
                result.append(draft)
            }
        }
        return result
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture)
            }
            .prefix(200)
            .map { $0 }
    }

    /// 将增量扫描结果合并进已有状态。忽略项只抑制 30 天；已完成事项只阻止同一次发生，
    /// 因而同名任务在新的日期仍可再次出现。
    public func merging(
        _ discovered: [ReminderCandidate],
        into existing: [ReminderCandidate],
        now: Date = .now,
        revalidatedCaptureIDs: Set<UUID> = []
    ) -> [ReminderCandidate] {
        var merged = existing.filter { reminder in
            // 只重验未经用户确认的自动候选，不能改动已安排、手动创建或用户关闭的事项。
            guard reminder.status == .proposed, reminder.origin == .discovered, reminder.analysis?.dailyReview == nil,
                  !Set(reminder.sourceCaptureIDs).isDisjoint(with: revalidatedCaptureIDs) else { return true }
            return discovered.contains { sameOccurrence(reminder, $0) }
        }
        for candidate in discovered {
            guard let index = merged.firstIndex(where: { $0.id == candidate.id || sameOccurrence($0, candidate) }) else {
                merged.append(candidate)
                continue
            }
            var current = merged[index]
            if current.analysis?.dailyReview != nil { continue }
            if current.status.isHistory {
                if blocks(candidate: candidate, existing: current, now: now) { continue }
                var next = candidate
                next.id = UUID(); next.status = .proposed; next.closedAt = nil
                next.completedAt = nil; next.dismissedUntil = nil; next.scheduledAt = nil
                merged.append(next)
                continue
            }
            var seenSourceIDs: Set<UUID> = []
            if candidate.analysis != nil {
                current.title = candidate.title; current.detail = candidate.detail
                current.analysis = candidate.analysis; current.recurrence = candidate.recurrence
                current.dueAt = candidate.dueAt
            }
            current.sourceCaptureIDs = (current.sourceCaptureIDs.filter { !revalidatedCaptureIDs.contains($0) } + candidate.sourceCaptureIDs)
                .filter { seenSourceIDs.insert($0).inserted }
            current.confidence = max(current.confidence, candidate.confidence)
            current.updatedAt = max(current.updatedAt, candidate.updatedAt)
            if current.dueAt == nil { current.dueAt = candidate.dueAt }
            if current.semanticKey.isEmpty { current.semanticKey = candidate.semanticKey }
            if current.status == .dismissed, (current.dismissedUntil ?? .distantPast) <= now {
                current.status = .proposed
                current.dismissedUntil = nil
            }
            merged[index] = current
        }
        return merged.sorted { lhs, rhs in
            let leftActive = lhs.status == .proposed || lhs.status == .scheduled || lhs.status == .snoozed
            let rightActive = rhs.status == .proposed || rhs.status == .scheduled || rhs.status == .snoozed
            if leftActive != rightActive { return leftActive }
            if leftActive {
                return (lhs.dueAt ?? lhs.updatedAt) < (rhs.dueAt ?? rhs.updatedAt)
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private struct Analysis {
        let title: String
        let dueAt: Date?
        let confidence: Double
        let reason: String
    }

    private func analyze(_ segment: RecordedText.Segment, base: Date) -> Analysis? {
        let compact = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = compact.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard compact.count >= 5, compact.count <= 300 else { return nil }
        guard !looksLikeNoise(lower), !looksLikeQuestion(compact), !looksLikeQuotedAdvice(compact), !looksCompleted(lower) else { return nil }
        // 左侧聊天内容是对方的陈述，不等于用户的待办；仅接受明确向用户发出的请求。
        if segment.speaker == .unknown || (segment.speaker == .other && !isDirectRequestToUser(lower)) { return nil }

        let actionVerbs = [
            "回复", "提交", "完成", "跟进", "处理", "联系", "确认", "预约", "支付", "续费",
            "更新", "发送", "整理", "准备", "参加", "取消", "购买", "缴纳", "检查", "修复",
            "发布", "交付", "申请", "撰写", "写一", "练习", "复盘", "follow up", "send", "submit", "finish",
            "call", "email", "pay", "renew", "schedule"
        ]
        let timeMarkers = [
            "今天", "明天", "后天", "本周", "这周", "下周", "周一", "周二", "周三", "周四",
            "周五", "周六", "周日", "星期", "月底", "月末", "日前", "之前", "截止", "到期",
            "每天", "每日", "每周", "每月", "today", "tomorrow", "next week", "deadline", "due"
        ]

        // “任务/完成/需要”等词经常出现在文章、网页和系统提示中，不能仅靠包含关系判定待办。
        // 采用正向准入：明确待办标签、用户第一人称承诺、句首指令、带时间的行动，或动作句本身。
        let hasTaskLabel = lower.range(
            of: #"(?i)^\s*【?(?:待办|任务|todo|action\s*item)】?\s*[:：\-]"#,
            options: .regularExpression
        ) != nil
        let hasReminderMarker = lower.range(of: #"^(?:请)?(?:记得|别忘|务必|提醒我)"#, options: .regularExpression) != nil
        let hasFirstPersonCommitment = ["我需要", "我要", "我计划", "我准备", "我打算", "我会"].contains(where: { lower.contains($0) })
        let hasLeadingDirective = lower.range(
            of: #"^(?:需要|应该|应当|必须|请|计划|准备|要在|需在|下一步)"#,
            options: .regularExpression
        ) != nil
        let isOtherPartyRequest = segment.speaker == .other && isDirectRequestToUser(lower)
        let hasStructuredRequirement = startsWithAnyAction(in: lower, verbs: actionVerbs)
            && ["需要包含", "要求包含", "需要完成", "需完成"].contains(where: { lower.contains($0) })
        let hasExplicitMarker = hasTaskLabel || hasReminderMarker
        // 无标记 OCR 只能提供明确写下的待办/提醒线索，不能把动词开头的网页、AI 回复当成自己的任务。
        guard segment.speaker == .user || isOtherPartyRequest || hasExplicitMarker else { return nil }
        let hasDirective = hasFirstPersonCommitment || hasLeadingDirective || isOtherPartyRequest
        let hasTime = timeMarkers.contains(where: { lower.contains($0) }) || containsExplicitDate(lower)
        let hasOwnedTimedAction = segment.speaker == .user && hasTime
        let matchedActionVerb = actionVerbs.first(where: { lower.contains($0) })
        let deadlineStateMarkers = ["到期", "过期", "还款日", "续费日", "缴费日", "生日", "纪念日", "会议时间", "预约时间"]
        // “24 小时过期”“每天最多登录一次”属于产品规则，不是次日的个人期限。
        let hasDeadlineState = hasCalendarDate(lower) && !looksLikeTechnicalPolicy(lower)
            && deadlineStateMarkers.contains(where: { lower.contains($0) })
        let hasAction = matchedActionVerb != nil || hasDeadlineState
        let hasRecurrence = ["每天", "每日", "每周", "每星期", "每月"].contains(where: { lower.contains($0) })
        let hasRecurringAction = hasRecurrence && !looksLikeTechnicalPolicy(lower)
            && lower.range(of: #"^(?:每天|每日|每周|每星期|每月).{0,24}(?:回复|提交|完成|跟进|处理|联系|确认|检查|发送|整理|缴纳|练习|支付)"#, options: .regularExpression) != nil
        let title = normalizedTitle(from: compact, actionVerbs: actionVerbs)
        let startsWithAction = actionVerbs.contains { title.localizedCaseInsensitiveContains($0) && title.lowercased().hasPrefix($0.lowercased()) }

        guard hasAction,
              hasExplicitMarker || hasDirective || hasStructuredRequirement || startsWithAction || hasDeadlineState || hasRecurringAction || hasOwnedTimedAction else { return nil }
        if looksLikeTechnicalPolicy(lower) && !hasExplicitMarker && !hasFirstPersonCommitment && !isOtherPartyRequest {
            return nil
        }
        guard title.count >= 5,
              DailySummaryContentFormatter.isUsableAction(title: title) else { return nil }

        let dueAt = inferredDueDate(in: compact, base: base)
        var confidence = 0.18
        if hasExplicitMarker { confidence += 0.34 }
        if hasDirective { confidence += 0.20 }
        if hasOwnedTimedAction { confidence += 0.20 }
        if hasAction { confidence += 0.24 }
        if startsWithAction { confidence += 0.18 }
        if hasTime { confidence += 0.10 }
        if hasDeadlineState { confidence += 0.18 }
        if hasRecurrence { confidence += 0.18 }
        if dueAt != nil { confidence += 0.06 }
        if lower.contains("截止") || lower.contains("deadline") || lower.contains("due") { confidence += 0.06 }
        if lower.contains("提醒我") || lower.contains("务必") { confidence += 0.08 }
        if ["例如", "比如", "示例", "假设", "页面显示", "文章提到"].contains(where: { lower.contains($0) }) {
            confidence -= 0.24
        }
        confidence = min(confidence, 0.96)
        guard confidence >= 0.60 else { return nil }
        let reason: String
        if isOtherPartyRequest {
            reason = "对方请求"
        } else if lower.contains("提醒我") || lower.contains("别忘") || lower.contains("记得") {
            reason = "明确提醒"
        } else if hasDeadlineState {
            reason = "期限事项"
        } else if hasTime {
            reason = "行动与时间"
        } else if hasExplicitMarker {
            reason = "明确待办"
        } else {
            reason = "未闭环行动"
        }
        return Analysis(title: title, dueAt: dueAt, confidence: confidence, reason: reason)
    }

    private func isDirectRequestToUser(_ text: String) -> Bool {
        text.range(of: #"(?:请你|请您|麻烦你|麻烦您|需要你|需要您|你能|您能|帮我|替我|给我)(?:.{0,40})(?:回复|提交|确认|处理|发送|准备|联系|安排|检查|修复|完成|整理|补充|更新|跟进|提供|反馈|评审)"#, options: .regularExpression) != nil
    }

    private func looksLikeTechnicalPolicy(_ text: String) -> Bool {
        let technical = ["无操作", "登录一次", "登录态", "session", "token", "ttl", "cookie", "缓存过期", "超时配置", "超时策略"]
        return technical.contains(where: text.contains) &&
            (text.contains("过期") || text.contains("分钟") || text.contains("小时") || text.contains("每天"))
    }

    private func hasCalendarDate(_ text: String) -> Bool {
        text.range(of: #"\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}[日号]?|\d{1,2}月\d{1,2}[日号]?"#, options: .regularExpression) != nil
    }

    private struct Resolution {
        let captureID: UUID
        let createdAt: Date
        let segment: RecordedText.Segment
    }

    private func isResolution(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["未完成", "尚未", "还没", "没有", "待完成", "如果", "假如", "计划", "准备", "明天", "需要"].contains(where: lower.contains) { return false }
        return looksCompleted(lower) || ["已取消", "不再需要", "不用再", "取消了"].contains(where: lower.contains)
    }

    private func resolves(title: String, with resolution: String) -> Bool {
        // 只认同一具体对象的明确完成/取消，不用“完成了”或模糊相似度关闭其他任务。
        let verbs = ["回复", "提交", "完成", "跟进", "处理", "联系", "确认", "预约", "支付", "续费", "发送", "整理", "准备", "检查", "修复", "发布", "交付", "申请", "撰写"]
        let cancellation = ["已取消", "不再需要", "不用再", "取消了"].contains(where: resolution.contains)
        let completeTask = ["已完成", "完成了", "已经完成"].contains(where: resolution.contains)
        let requiredVerbs = verbs.filter { title.contains($0) }
        guard cancellation || completeTask || (!requiredVerbs.isEmpty && requiredVerbs.allSatisfy(resolution.contains)) else { return false }
        var object = title.replacingOccurrences(of: #"(?:今天|明天|后天|本周|这周|下周|每天|每日|每周|每月|(?:下|本|这)?(?:周|星期)[一二三四五六日天])|(?:\d{4}[-/年])?\d{1,2}[-/月]\d{1,2}[日号]?|(?:上午|下午|晚上|早上)?[零一二三四五六七八九十两\d]+(?:[:：点时][零一二三四五六七八九十两\d]*分?半?)"#, with: "", options: .regularExpression)
        for prefix in ["待办", "任务", "提醒我", "我计划", "我需要", "我准备", "我要", "我会", "请你", "麻烦你"] + verbs {
            object = object.replacingOccurrences(of: prefix, with: "")
        }
        object = fingerprint(object)
        return object.count >= 4 && fingerprint(resolution).contains(object)
    }

    private func looksLikeNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let noisePrefixes = ["//", "/*", "#!", "$ ", "> ", "select ", "insert ", "update ", "delete "]
        let noisePhrases = [
            "test log", "debug log", "lorem ipsum", "console.log", "system.out", "测试日志",
            "通讯录", "工作台 微盘", "new tab", "function ", "class ", "public static", "private func"
        ]
        let navigationTerms = ["工作台", "通讯录", "微盘", "更多", "搜索", "智能文档", "源码学习", "设计模式"]
        let navigationMatches = navigationTerms.filter { trimmed.contains($0) }.count
        let meaningfulCharacters = trimmed.filter { $0.isLetter || $0.isNumber }
        let symbolRatio = trimmed.isEmpty ? 0 : Double(trimmed.count - meaningfulCharacters.count) / Double(trimmed.count)
        return noisePrefixes.contains(where: { trimmed.hasPrefix($0) })
            || noisePhrases.contains(where: { trimmed.contains($0) })
            || navigationMatches >= 3
            || (trimmed.count >= 8 && symbolRatio > 0.45)
            || trimmed.range(of: #"^[/\\]{1,2}(todo|fixme)\b"#, options: .regularExpression) != nil
    }

    private func looksLikeQuestion(_ text: String) -> Bool {
        let compact = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n。；;"))
        let uncertaintyMarkers = ["是不是", "是否", "能否", "要不要", "可不可以", "可能", "好像", "我记得"]
        let assistantPrompts = ["你想怎么处理", "您想怎么处理", "问下你", "请告诉我", "你希望我", "您希望我", "需要我怎么", "还有什么需要处理"]
        let questionEndings = ["吗", "呢", "吧", "么", "？", "?"]
        return questionEndings.contains(where: { compact.hasSuffix($0) })
            || (uncertaintyMarkers.contains(where: { compact.contains($0) }) && !compact.contains("提醒我"))
            || assistantPrompts.contains(where: compact.contains)
    }

    private func looksLikeQuotedAdvice(_ text: String) -> Bool {
        let markers = ["不要问", "而要问", "你应该问", "文章提到", "文中提到", "举例来说"]
        return markers.contains(where: text.contains)
    }

    private func looksCompleted(_ text: String) -> Bool {
        if ["未完成", "尚未完成", "还没完成", "没有完成"].contains(where: { text.contains($0) }) { return false }
        let completedMarkers = [
            "已完成", "已经完成", "完成了", "已提交", "已经提交", "已回复", "已经回复",
            "已处理", "已经处理", "已解决", "搞定了", "最终提交", "合并到main", "合并到 main",
            "测试通过", "done", "completed", "finished"
        ]
        return completedMarkers.contains(where: { text.contains($0) })
            || text.range(of: #"^完成[\s:：·\-]"#, options: .regularExpression) != nil
    }

    private func startsWithAnyAction(in text: String, verbs: [String]) -> Bool {
        verbs.contains { text.hasPrefix($0.lowercased()) }
    }

    private func normalizedTitle(from source: String, actionVerbs: [String]) -> String {
        var title = source
            .replacingOccurrences(of: #"^\[聊天·(?:自己|对方|角色未知)\]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s•·●\-*]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"(?i)^(待办|todo|action item|任务|下一步)\s*[:：\-]\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"^(请)?(?:提醒我|记得|别忘|务必)\s*[:：，,]?\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for separator in ["，", ","] {
            guard let index = title.firstIndex(of: Character(separator)) else { continue }
            let leadingClause = String(title[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if leadingClause.count >= 5, actionVerbs.contains(where: { leadingClause.localizedCaseInsensitiveContains($0) }) {
                title = leadingClause
                break
            }
        }
        // 不通过字符截取制造半句；无法形成完整标题的候选由质量门拒绝。
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n。；;"))
        if title.hasPrefix("完成"), source.range(of: #"^(?:待办|任务|todo)\s*[:：]|^(?:提醒我|记得|别忘)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            title = "待" + title
        }
        return title
    }

    /// Title normalization computed once per reminder instead of once per comparison.
    struct TitleKey: Sendable {
        let fingerprint: String
        let pairs: Set<String>
    }
    func titleKey(_ title: String) -> TitleKey {
        let value = fingerprint(title)
        return TitleKey(fingerprint: value, pairs: characterPairs(in: value))
    }

    /// Precomputed comparison keys for one pass over existing reminders. Exact fingerprints are
    /// answered by lookup; fuzzy comparisons skip titles whose bigram counts make 0.72 overlap impossible.
    public struct BlockIndex: Sendable {
        let extractor: ReminderExtractor
        let entries: [(reminder: ReminderCandidate, key: TitleKey)]
        let exact: [String: [Int]]
        public init(_ reminders: [ReminderCandidate], extractor: ReminderExtractor = ReminderExtractor()) {
            self.extractor = extractor
            entries = reminders.map { ($0, extractor.titleKey($0.title)) }
            var exact: [String: [Int]] = [:]
            for (i, entry) in entries.enumerated() { exact[entry.key.fingerprint, default: []].append(i) }
            self.exact = exact
        }
        public func blocks(_ candidate: ReminderCandidate, now: Date, where include: (ReminderCandidate) -> Bool = { _ in true }) -> Bool {
            let key = extractor.titleKey(candidate.title)
            if let ids = exact[key.fingerprint], ids.contains(where: { include(entries[$0].reminder) && extractor.blocks(candidate: candidate, candidateKey: key, existing: entries[$0].reminder, existingKey: entries[$0].key, now: now) }) {
                return true
            }
            guard candidate.analysis == nil else { return false }
            return entries.contains { entry in
                guard entry.key.fingerprint != key.fingerprint, ReminderExtractor.mayBeEquivalent(key, entry.key), include(entry.reminder) else { return false }
                return extractor.blocks(candidate: candidate, candidateKey: key, existing: entry.reminder, existingKey: entry.key, now: now)
            }
        }
    }
    static func mayBeEquivalent(_ lhs: TitleKey, _ rhs: TitleKey) -> Bool {
        let shorter = min(lhs.fingerprint.count, rhs.fingerprint.count)
        if shorter >= 8 { return true } // Containment can match titles of any length ratio.
        let small = Double(min(lhs.pairs.count, rhs.pairs.count)), large = Double(max(lhs.pairs.count, rhs.pairs.count))
        return large == 0 || small / large >= 0.72
    }

    private func isSemanticallyEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        isSemanticallyEquivalent(titleKey(lhs), titleKey(rhs))
    }
    private func isSemanticallyEquivalent(_ lhsKey: TitleKey, _ rhsKey: TitleKey) -> Bool {
        let left = lhsKey.fingerprint
        let right = rhsKey.fingerprint
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        if min(left.count, right.count) >= 8 && (left.contains(right) || right.contains(left)) { return true }

        let leftPairs = lhsKey.pairs
        let rightPairs = rhsKey.pairs
        guard !leftPairs.isEmpty, !rightPairs.isEmpty else { return false }
        let intersection = leftPairs.intersection(rightPairs).count
        let union = leftPairs.union(rightPairs).count
        return union > 0 && Double(intersection) / Double(union) >= 0.72
    }

    private func sameOccurrence(_ lhs: ReminderCandidate, _ rhs: ReminderCandidate) -> Bool {
        sameOccurrence(lhs, titleKey(lhs.title), rhs, titleKey(rhs.title))
    }
    private func sameOccurrence(_ lhs: ReminderCandidate, _ lhsKey: TitleKey, _ rhs: ReminderCandidate, _ rhsKey: TitleKey) -> Bool {
        if lhs.analysis != nil || rhs.analysis != nil {
            if lhs.id == rhs.id { return true }
            // Model decisions supply identity. Fuzzy character overlap must not merge different
            // clients/projects or unrelated conversations after the semantic audit accepted both.
            guard lhsKey.fingerprint == rhsKey.fingerprint,
                  !Set(lhs.sourceCaptureIDs).isDisjoint(with: rhs.sourceCaptureIDs) else { return false }
        } else {
            guard isSemanticallyEquivalent(lhsKey, rhsKey) else { return false }
        }
        switch (lhs.dueAt, rhs.dueAt) {
        case let (left?, right?):
            return Calendar.current.isDate(left, inSameDayAs: right)
        case (nil, nil):
            return true
        default:
            return true
        }
    }

    func blocks(candidate: ReminderCandidate, existing: ReminderCandidate, now: Date) -> Bool {
        blocks(candidate: candidate, candidateKey: titleKey(candidate.title), existing: existing, existingKey: titleKey(existing.title), now: now)
    }
    func blocks(candidate: ReminderCandidate, candidateKey: TitleKey, existing: ReminderCandidate, existingKey: TitleKey, now: Date) -> Bool {
        if candidate.analysis != nil {
            guard existing.id == candidate.id || existingKey.fingerprint == candidateKey.fingerprint else { return false }
        } else {
            guard isSemanticallyEquivalent(existingKey, candidateKey) else { return false }
        }
        switch existing.status {
        case .proposed, .planned, .scheduled, .snoozed:
            return sameOccurrence(existing, existingKey, candidate, candidateKey)
        case .dismissed:
            return (existing.dismissedUntil ?? existing.updatedAt.addingTimeInterval(30 * 86_400)) > now
                && sameOccurrence(existing, existingKey, candidate, candidateKey)
        case .completed, .cancelled:
            if let oldDate = existing.dueAt, let newDate = candidate.dueAt {
                return Calendar.current.isDate(oldDate, inSameDayAs: newDate)
            }
            return now.timeIntervalSince(existing.completedAt ?? existing.updatedAt) < 7 * 86_400
        }
    }

    private func fingerprint(_ source: String) -> String {
        let folded = source.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let taskMarkers = ["待办", "todo", "actionitem", "任务", "记得", "请", "需要", "务必"]
        var compact = String(folded.filter { $0.isLetter || $0.isNumber })
        for marker in taskMarkers {
            compact = compact.replacingOccurrences(of: marker, with: "")
        }
        return compact
    }

    private func characterPairs(in source: String) -> Set<String> {
        let characters = Array(source)
        guard characters.count >= 2 else { return Set(characters.map(String.init)) }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }

    private func containsExplicitDate(_ text: String) -> Bool {
        text.range(of: #"\d{1,4}[-/.年]\d{1,2}(?:[-/.月]\d{1,2})?"#, options: .regularExpression) != nil
            || text.range(of: #"\d{1,2}月\d{1,2}[日号]?"#, options: .regularExpression) != nil
            || text.range(of: #"\d+\s*(?:分钟|小时|天)后"#, options: .regularExpression) != nil
    }

    private func inferredDueDate(in text: String, base: Date) -> Date? {
        let calendar = Calendar.current
        if let parts = firstMatch(#"(?<!\d)(\d+)\s*(分钟|小时|天)后"#, in: text),
           let amount = Int(parts[1]) {
            let component: Calendar.Component = parts[2] == "分钟" ? .minute : (parts[2] == "小时" ? .hour : .day)
            return calendar.date(byAdding: component, value: amount, to: base)
        }
        let time = inferredTime(in: text)
        if let exactDate = inferredExplicitDate(in: text, base: base, calendar: calendar) {
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: exactDate)
        }

        let lower = text.lowercased()
        let dayOffset: Int?
        if text.contains("后天") {
            dayOffset = 2
        } else if text.contains("明天") || lower.contains("tomorrow") {
            dayOffset = 1
        } else if text.contains("今天") || text.contains("今晚") || lower.contains("today") || text.contains("每天") || text.contains("每日") {
            dayOffset = 0
        } else if text.contains("月底") || text.contains("月末") {
            guard let interval = calendar.dateInterval(of: .month, for: base),
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: lastDay)
        } else if let weekdayDate = inferredWeekday(in: text, base: base, calendar: calendar) {
            return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: weekdayDate)
        } else if text.contains("下周") || lower.contains("next week") {
            dayOffset = 7
        } else {
            dayOffset = nil
        }

        if let dayOffset,
           let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: base)) {
            guard let candidate = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: targetDay) else {
                return nil
            }
            if (text.contains("每天") || text.contains("每日")), candidate <= base {
                return calendar.date(byAdding: .day, value: 1, to: candidate)
            }
            return candidate
        }
        return nil
    }

    private func inferredTime(in text: String) -> (hour: Int, minute: Int) {
        if let parts = firstMatch(#"(?<!\d)(\d{1,2})(?:[:：点时])(\d{1,2})?"#, in: text),
           let rawHour = Int(parts[1]) {
            var hour = min(max(rawHour, 0), 23)
            let minute = parts.count > 2 ? min(max(Int(parts[2]) ?? 0, 0), 59) : 0
            if (text.contains("下午") || text.contains("晚上")) && hour < 12 { hour += 12 }
            if text.contains("中午") && hour < 11 { hour += 12 }
            return (hour, minute)
        }
        if let parts = firstMatch(#"([零〇一二两三四五六七八九十]{1,3})点(半|一刻|三刻|[零〇一二两三四五六七八九十]{1,3}分?)?"#, in: text),
           var hour = chineseNumber(parts[1]) {
            let minuteToken = parts.count > 2 ? parts[2] : ""
            let minute: Int
            switch minuteToken {
            case "半": minute = 30
            case "一刻": minute = 15
            case "三刻": minute = 45
            default: minute = chineseNumber(minuteToken.replacingOccurrences(of: "分", with: "")) ?? 0
            }
            if (text.contains("下午") || text.contains("晚上") || text.contains("今晚")) && hour < 12 { hour += 12 }
            if text.contains("中午") && hour < 11 { hour += 12 }
            return (min(max(hour, 0), 23), min(max(minute, 0), 59))
        }
        if text.contains("早上") || text.contains("上午") { return (9, 0) }
        if text.contains("中午") { return (12, 0) }
        if text.contains("下午") { return (15, 0) }
        if text.contains("晚上") || text.contains("今晚") { return (20, 0) }
        return (9, 0)
    }

    private func chineseNumber(_ source: String) -> Int? {
        guard !source.isEmpty else { return nil }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if source == "十" { return 10 }
        if let ten = source.firstIndex(of: "十") {
            let left = source[..<ten].first.flatMap { digits[$0] } ?? 1
            let rightStart = source.index(after: ten)
            let right = rightStart < source.endIndex ? (digits[source[rightStart]] ?? 0) : 0
            return left * 10 + right
        }
        return source.reduce(0) { partial, character in
            guard let value = digits[character] else { return partial }
            return partial * 10 + value
        }
    }

    private func inferredRecurrence(in text: String) -> ReminderRecurrence {
        if text.contains("每天") || text.contains("每日") { return .daily }
        if text.contains("每周") || text.contains("每星期") { return .weekly }
        if text.contains("每月") { return .monthly }
        return .none
    }

    private func detail(for capture: CaptureRecord, segment: String, reason: String) -> String {
        let source = capture.sourceAppName ?? capture.eventTemplate.title
        let excerpt = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(reason) · \(source)\n\(excerpt)"
    }

    private func inferredExplicitDate(in text: String, base: Date, calendar: Calendar) -> Date? {
        if let parts = firstMatch(#"(?<!\d)(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})[日号]?"#, in: text),
           let year = Int(parts[1]), let month = Int(parts[2]), let day = Int(parts[3]) {
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        if let parts = firstMatch(#"(?<!\d)(\d{1,2})月(\d{1,2})[日号]?"#, in: text),
           let month = Int(parts[1]), let day = Int(parts[2]) {
            let baseYear = calendar.component(.year, from: base)
            let candidate = calendar.date(from: DateComponents(year: baseYear, month: month, day: day))
            if let candidate, candidate < calendar.startOfDay(for: base) {
                return calendar.date(from: DateComponents(year: baseYear + 1, month: month, day: day))
            }
            return candidate
        }
        if let parts = firstMatch(#"(?<!\d)(\d{1,2})[/-](\d{1,2})(?!\d)"#, in: text),
           let month = Int(parts[1]), let day = Int(parts[2]) {
            let baseYear = calendar.component(.year, from: base)
            let candidate = calendar.date(from: DateComponents(year: baseYear, month: month, day: day))
            if let candidate, candidate < calendar.startOfDay(for: base) {
                return calendar.date(from: DateComponents(year: baseYear + 1, month: month, day: day))
            }
            return candidate
        }
        return nil
    }

    private func inferredWeekday(in text: String, base: Date, calendar: Calendar) -> Date? {
        guard let parts = firstMatch(#"((?:下|本|这)?(?:周|星期))([一二三四五六日天])"#, in: text) else { return nil }
        let targetWeekday: Int
        switch parts[2] {
        case "一": targetWeekday = 2
        case "二": targetWeekday = 3
        case "三": targetWeekday = 4
        case "四": targetWeekday = 5
        case "五": targetWeekday = 6
        case "六": targetWeekday = 7
        default: targetWeekday = 1
        }
        let baseDay = calendar.startOfDay(for: base)
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: baseDay)?.start else { return nil }
        let weekStartWeekday = calendar.component(.weekday, from: weekStart)
        let offsetWithinWeek = (targetWeekday - weekStartWeekday + 7) % 7
        let weekOffset = parts[1].contains("下") ? 7 : 0
        guard let candidate = calendar.date(byAdding: .day, value: weekOffset + offsetWithinWeek, to: weekStart) else { return nil }
        if candidate < baseDay && !parts[1].contains("本") && !parts[1].contains("这") {
            return calendar.date(byAdding: .day, value: 7, to: candidate)
        }
        return candidate
    }

    private func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}

@MainActor
public final class LocalNotificationScheduler {
    public nonisolated static let categoryIdentifier = "RECALL_REMINDER"
    public nonisolated static let completeActionIdentifier = "RECALL_COMPLETE"
    public nonisolated static let snoozeHourActionIdentifier = "RECALL_SNOOZE_HOUR"
    public nonisolated static let snoozeTomorrowActionIdentifier = "RECALL_SNOOZE_TOMORROW"

    public init() {}

    public func configureReminderActions() throws {
        let center = try notificationCenter()
        let complete = UNNotificationAction(
            identifier: Self.completeActionIdentifier,
            title: "完成",
            options: []
        )
        let snoozeHour = UNNotificationAction(
            identifier: Self.snoozeHourActionIdentifier,
            title: "1 小时后提醒",
            options: []
        )
        let snoozeTomorrow = UNNotificationAction(
            identifier: Self.snoozeTomorrowActionIdentifier,
            title: "明天提醒",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [complete, snoozeHour, snoozeTomorrow],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    public func requestAuthorization() async throws -> Bool {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                throw notificationError(from: error)
            }
        @unknown default:
            return false
        }
    }

    public func schedule(_ reminder: ReminderCandidate) async throws {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ReminderNotificationError.authorizationRequired
        }
        guard reminder.dueAt != nil else { throw ReminderNotificationError.missingDueDate }
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        let detailLines = reminder.detail.components(separatedBy: .newlines).filter { !$0.isEmpty }
        content.body = detailLines.last ?? "现在适合处理这件事。"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["reminderID": reminder.id.uuidString]
        let requests = ReminderTimeline.requests(for: reminder)
        guard !requests.isEmpty else { throw ReminderNotificationError.missingDueDate }
        // Replace every request this reminder may own, so a shape change (snooze, short month) leaves nothing stale.
        center.removePendingNotificationRequests(withIdentifiers: ReminderTimeline.identifiers(for: reminder.id))
        do {
            for item in requests {
                let trigger: UNCalendarNotificationTrigger
                switch item.trigger {
                case .once(let date):
                    trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
                case .repeating(let components):
                    trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                }
                try await center.add(UNNotificationRequest(identifier: item.identifier, content: content, trigger: trigger))
            }
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: ReminderTimeline.identifiers(for: reminder.id))
            throw notificationError(from: error)
        }
        let pending = Set(await center.pendingNotificationRequests().map(\.identifier))
        guard requests.allSatisfy({ pending.contains($0.identifier) }) else {
            center.removePendingNotificationRequests(withIdentifiers: ReminderTimeline.identifiers(for: reminder.id))
            throw ReminderNotificationError.notificationSchedulingFailed
        }
    }

    /// Current authorization without prompting. Nil when the host cannot use notifications.
    public func authorizationGranted() async -> Bool? {
        guard let center = try? notificationCenter() else { return nil }
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional: return true
        case .notDetermined: return nil
        default: return false
        }
    }

    /// 仅核验由 Recall 创建的通知标识；不读取或暴露其他应用的通知内容。
    public func deliveryStates(for reminders: [ReminderCandidate]) async throws -> [UUID: ReminderDeliveryState] {
        let remindersWithDates = reminders.filter { $0.dueAt != nil }
        guard !remindersWithDates.isEmpty else { return [:] }

        let center = try notificationCenter()
        let pendingIdentifiers = Set(await center.pendingNotificationRequests().compactMap { ReminderTimeline.reminderID(fromRequest: $0.identifier) })
        let deliveredIdentifiers = Set(await center.deliveredNotifications().compactMap { ReminderTimeline.reminderID(fromRequest: $0.request.identifier) })

        return Dictionary(uniqueKeysWithValues: remindersWithDates.map { reminder in
            let identifier = reminder.id
            let status: ReminderDeliveryState
            // A repeating reminder can be both delivered and pending; pending means the future is covered.
            if pendingIdentifiers.contains(identifier) {
                status = .pending
            } else if deliveredIdentifiers.contains(identifier) {
                status = .delivered
            } else {
                status = .notFound
            }
            return (reminder.id, status)
        })
    }

    public func scheduleDailyReview(hour: Int = 18, minute: Int = 0) async throws {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ReminderNotificationError.authorizationRequired
        }
        let content = UNMutableNotificationContent()
        content.title = "Recall 每日回顾"
        content.body = "查看今天已显式记录的工作节点与待确认事项。"
        content.sound = .default
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let request = UNNotificationRequest(
            identifier: "im.recall.app.daily-review",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        do {
            try await center.add(request)
        } catch {
            throw notificationError(from: error)
        }
    }

    public func deliverDailyBriefing(_ summary: DailySummary) async throws {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ReminderNotificationError.authorizationRequired
        }
        let content = UNMutableNotificationContent()
        content.title = "Recall 已生成个人简报"
        content.body = summary.modelOverview ?? summary.briefing?.headline ?? "每日回顾已生成，可以打开查看。"
        content.sound = .default
        content.userInfo = ["dailySummaryID": summary.id.uuidString]
        let identifier = "im.recall.app.daily-summary.\(Int(summary.day.timeIntervalSince1970))"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        do {
            try await center.add(request)
        } catch {
            throw notificationError(from: error)
        }
    }

    public func deliverWeeklyReview(_ report: WeeklyReport) async throws {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ReminderNotificationError.authorizationRequired
        }
        let content = UNMutableNotificationContent()
        content.title = "你的\(report.template.name)已整理好"
        content.body = "回看这段时间的变化与经历。"
        content.sound = .default
        content.userInfo = ["weeklyReportID": report.id.uuidString]
        let identifier = "im.recall.app.weekly-review." + report.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        } catch { throw notificationError(from: error) }
    }

    /// A plain informational notice (meeting brief). Requires existing permission; never asks for it.
    public func deliverNotice(title: String, body: String, identifier: String) async throws {
        let center = try notificationCenter()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw ReminderNotificationError.authorizationRequired
        }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        } catch { throw notificationError(from: error) }
    }

    public func cancelDailyReview() {
        guard isNotificationHostAvailable else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["im.recall.app.daily-review"])
    }

    public func cancel(_ reminder: ReminderCandidate) {
        guard isNotificationHostAvailable else { return }
        let identifiers = ReminderTimeline.identifiers(for: reminder.id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func cancelAll(_ reminders: [ReminderCandidate]) {
        guard isNotificationHostAvailable else { return }
        let identifiers = reminders.flatMap { ReminderTimeline.identifiers(for: $0.id) }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private var isNotificationHostAvailable: Bool {
        let mainBundle = Bundle.main
        return mainBundle.bundleURL.pathExtension.lowercased() == "app"
            && !(mainBundle.bundleIdentifier?.isEmpty ?? true)
    }

    private func notificationCenter() throws -> UNUserNotificationCenter {
        guard isNotificationHostAvailable else {
            throw ReminderNotificationError.hostApplicationRequired
        }
        return UNUserNotificationCenter.current()
    }

    private func notificationError(from error: Error) -> ReminderNotificationError {
        let systemError = error as NSError
        if systemError.domain == "UNErrorDomain" && systemError.code == 1 {
            return .notificationNotPermitted
        }
        return .notificationSchedulingFailed
    }
}

public enum ReminderDeliveryState: String, Sendable, Hashable {
    /// 通知请求已被 macOS 接受，等待达到用户确认的时间。
    case pending
    /// macOS 已将通知交付给通知中心；用户是否已阅读由系统负责。
    case delivered
    /// 本地记录显示已安排，但系统队列中没有对应请求或已投递通知。
    case notFound
}

public enum ReminderNotificationError: LocalizedError {
    case authorizationRequired
    case missingDueDate
    case hostApplicationRequired
    case notificationNotPermitted
    case notificationSchedulingFailed

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: "请先允许应用发送提醒通知。"
        case .missingDueDate: "请为提醒选择一个时间。"
        case .hostApplicationRequired: "提醒通知需要从 Recall.app 启动；当前调试可执行文件无法安全请求系统通知。"
        case .notificationNotPermitted: "macOS 拒绝了此提醒请求。请退出并重新通过 Recall.app 启动，然后在系统设置 → 通知 → Recall 中允许通知。"
        case .notificationSchedulingFailed: "提醒未能安排。请检查系统设置 → 通知 → Recall 的授权状态后重试。"
        }
    }
}
