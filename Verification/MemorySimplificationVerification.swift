import Foundation
import RecallKit

/// Invented examples exercise user-visible contracts, not real screenshots or personal data.
@MainActor
enum MemorySimplificationVerification {
    private struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    private static func capture(_ text: String, at date: Date, title: String = "合成对话") -> CaptureRecord {
        CaptureRecord(eventTemplate: .manualMoment, createdAt: date, sourceAppName: "合成记录", sourceBundleIdentifier: "test.simplification",
            windowTitle: title, contentHash: UUID().uuidString, ocrText: text, textOrigin: .screenOCR)
    }
    static func run() async throws {
        try await automaticRange()
        try consolidation()
        try await groupedAudit()
        try qualification()
        try contextIsolation()
        try await conflictsAndOverrides()
        try expiration()
        try await legacyAndCorrection()
        print("PASS: simplified memory/review contracts cover date scope, automatic categories, grouping audits, qualification, context, corrections, expiry and migration")
    }
    private static func automaticRange() async throws {
        let now = Date.now, start = now.addingTimeInterval(-86_400 * 6)
        func note(_ title: String, _ detail: String, _ category: ReviewCategory = .unclassified) throws -> CaptureRecord {
            try ManualMatterNote(title: title, detail: detail, status: .progressed, eventAt: start.addingTimeInterval(60), reviewCategory: category).capture(recordedAt: start.addingTimeInterval(60))
        }
        let records = [try note("Atlas 发布流程页面改版", "发布历史布局已调整，生产发布尚未进行。"),
                       try note("家庭植物观察", "和家人观察院中叶片，记录了颜色的变化。"),
                       try note("木刻基础练习", "完成第一张木刻练习，尚未开始第二张。")]
        let state = RecallState(captures: records), period = ReviewPeriod(start: start, end: now)
        let engine = WeeklyReviewEngine()
        let all = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .personal), now: now)
        let work = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .work), now: now)
        let study = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .learning), now: now)
        try expect(all.sourceIDs == Set(records.map(\.id)), "普通回顾不能要求选择主题或只读取当天")
        try expect(work.sourceIDs == [records[0].id] && study.sourceIDs == [records[2].id], "工作/学习模板应自动找到适用内容并隔离生活")
        for title in ["页面改版讨论覆盖布局、发布历史与资产变动", "流程页左侧导航样式与状态图标调整讨论", "流程页改版讨论聚焦当前步骤状态与图标"] {
            try expect(ReviewCategoryIndex.inferredCategory(title: title, details: []) == .work, "同一次页面设计的不同表述不应因分类差异阻止归并")
        }
        let files = engine.topics(in: state), index = ReviewWorkspaceIndex(state: state, topics: files)
        try expect(index.preview(in: period, kind: .work, scope: ReviewScope()).eligibleTopicCount == work.items.count, "生成按钮预览与实际自动分类必须一致")
        let selected = ReviewScope(topicIDs: [files.first { $0.evidenceIDs.contains(records[0].id) }!.id])
        let specific = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .project), scope: selected, now: now)
        try expect(specific.sourceIDs == [records[0].id], "主题详情中的单独回顾不得带入别的事")
        let learningID = files.first { $0.evidenceIDs.contains(records[2].id) }!.id
        let learningReview = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .learning), scope: ReviewScope(topicIDs: [learningID]), now: now)
        try expect(learningReview.sourceIDs == [records[2].id], "非工作主题也能从详情单独生成回顾")
        let renewed = try await engine.generate(in: state, period: period, template: ReviewTemplate(kind: .personal), now: now)
        try expect(renewed.sourceIDs.count == 3, "回到普通回顾不能遗留上次的主题限制")
    }
    private static func item(_ id: String, title: String, status: WorkEpisodeStatus = .progressed, date: Date = .now, reference: Bool = false) -> ReviewItem {
        let proof = ReviewExcerpt(id: UUID(), date: date, text: title + "已完成方案讨论，尚未确认上线。", status: status, sourceIDs: [UUID()])
        return ReviewItem(id: (reference ? "reference:" : "") + id, title: title, category: .work,
            section: status == .blocked ? .open : .progress, previous: nil, excerpts: [proof], featuredIDs: [proof.id], nextAction: nil, nextActionSourceIDs: [])
    }
    private static func consolidation() throws {
        let first = item("layout", title: "Atlas 发布流程 · 布局调整", status: .completed, date: .now.addingTimeInterval(-86_400))
        let second = item("steps", title: "Atlas 发布流程 · 步骤导航", status: .blocked)
        let different = item("other", title: "Atlas 支付接口 · 重复回调")
        let ledger = ReviewConsolidation.local([first, second, different])
        let group = ledger.first { $0.memberTopicIDs != nil }!
        try expect(ledger.count == 4 && group.memberTopicIDs?.count == 2 && group.section == .open, "同一具体对象应合并阅读，但原始材料和最新阻碍必须保留")
        try expect(Set(group.requiredExcerptIDs) == Set(first.requiredExcerptIDs + second.requiredExcerptIDs), "归并不能漏掉任一成员的重要结果和最新状态")
        try expect(Set(group.sourceIDs) == Set(first.sourceIDs + second.sourceIDs), "归并必须保留全部来源")
        let rows = ReviewDigest.candidates(ledger, period: ReviewPeriod(start: .now.addingTimeInterval(-86_400 * 7), end: .now), limit: 8)
        try expect(rows.count == 2 && rows.contains { $0.id == group.id }, "归并后的正文不能又重复显示成员")
        try expect(ReviewConsolidation.combine([first, item("ref", title: first.title, reference: true)], title: "Atlas 发布流程") == nil, "本人事项与资料不允许混并")
        try expect(ReviewConsolidation.local([item("a", title: "Atlas · 发布流程"), item("b", title: "Atlas · 支付接口")]).count == 2, "仅共享产品名不能自动归并")
    }
    private static func groupedAudit() async throws {
        let now = Date.now, date = now.addingTimeInterval(-86_400)
        let records = try ["Atlas 发布页面布局调整", "Atlas 发布历史列表设计", "Atlas 发布步骤导航讨论"].map { title in
            try ManualMatterNote(title: title, detail: title + "已明确设计方案，尚未开始生产发布。", status: .progressed,
                eventAt: date, reviewCategory: .work).capture(recordedAt: date)
        }
        var state = RecallState(captures: records); state.privacy.cloudUseEnabled = true
        let period = ReviewPeriod(start: now.addingTimeInterval(-86_400 * 6), end: now)
        for mode in [GroupingProbe.Mode.valid, .rejectGroup, .invalidID] {
            let probe = GroupingProbe(mode: mode)
            let report = try await WeeklyReviewEngine().generate(in: state, period: period, template: ReviewTemplate(kind: .personal), responder: probe, now: now)
            try expect(report.sourceIDs == Set(records.map(\.id)), "精选归并不能删除未选的来源")
            if mode == .valid {
                try expect(report.digestRows.count == 1 && report.digestRows[0].item.memberTopicIDs?.count == 3 && !report.refinementPending,
                    "即使只有三项，也应先归并同一件事再成文和核验")
                try expect(report.digestRows[0].summary.contains("尚未"), "归并不能把方案讨论写成已经上线")
            } else if mode == .rejectGroup {
                try expect(report.digestRows.isEmpty && report.refinementPending, "独立核验不认可同一事项时，不能以原文拼接的归并结果回填正文")
            } else {
                try expect(report.refinementPending && !report.markdown.contains("invalid-topic"), "模型伪造归并成员 ID 必须被拒绝")
            }
        }
    }
    private static func qualification() throws {
        let now = Date.now
        let first = capture("[聊天·自己] 我喜欢简洁的说明。\n[聊天·自己] 这次我喜欢蓝色配色。\n[聊天·对方] 我喜欢详细说明。\n[内容·资料] 我希望每周都做十件事。", at: now.addingTimeInterval(-86_400 * 2))
        let repeatShot = capture(first.ocrText, at: now)
        var state = RecallState(captures: [first, repeatShot])
        let engine = MemoryKnowledgeEngine()
        var ledger = engine.reconcile(state, force: true, now: now)
        let request = capture("[聊天·自己] 我希望这个输入框变小一点。", at: now)
        let requestLedger = engine.reconcile(RecallState(captures: [request]), force: true, now: now)
        try expect(!requestLedger.claims.contains { $0.kind == .goal }, "普通的我希望/我想要页面改动不能归为人生或长期目标")
        try expect(MemoryDirective.parse("记住：我希望以后回答简洁一点")?.kind == .preference, "希望调整表达方式应保存为偏好而不是目标")
        let personal = ledger.claims.filter { $0.kind.isPersonal }
        try expect(personal.count == 1 && personal[0].state == .tentative, "跨日重拍同一对话不能把偶然表达变成稳定偏好；临时/他人/资料应排除")
        let independent = capture("[聊天·自己] 我喜欢简洁的说明。", at: now, title: "另一段独立讨论")
        state.captures.append(independent)
        ledger = engine.reconcile(state, force: true, now: now)
        try expect(ledger.claims.contains { $0.kind == .preference && $0.usable(at: now) }, "不同日期与独立语境的重复本人表达可以自动生效，不强制逐条确认")
        try expect(MemoryLibraryCategory.all.includes(.preference) && !MemoryLibraryCategory.all.includes(.reference) && !MemoryLibraryCategory.all.includes(.event), "长期记忆默认应展示个人信息，资料与事件各归其位")
    }
    private static func contextIsolation() throws {
        let now = Date.now
        let directive = MemoryDirective.parse("记住：Atlas 项目页面采用森林绿配色")!
        try expect(directive.scope == .project && directive.scopeID != nil, "命名项目要求不能成为全局偏好")
        let source = CaptureRecord(eventTemplate: .manualMoment, createdAt: now, contentHash: "synthetic-scope", ocrText: directive.content, textOrigin: .userInput, memoryDirective: directive)
        var state = RecallState(captures: [source]); state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state, force: true, now: now)
        let reader = MemoryRetrievalEngine(), project = reader.plan(question: "Atlas 项目的页面怎么配色", state: state, fallback: [source], now: now)
        let other = reader.plan(question: "Nova 项目的页面怎么配色", state: state, fallback: [source], now: now)
        try expect(project.preferences?.contains("森林绿") == true && project.preferenceSourceIDs.contains(source.id), "项目记忆必须可在相关问题中使用并追溯")
        try expect(other.preferences == nil && other.evidence.isEmpty, "项目偏好不得经原始回退来源绕过范围进入别的项目")
        var projectLength = state.memoryKnowledge.claims.first { $0.explicit }!
        projectLength.content = "Atlas 项目回答简洁一点"; projectLength.kind = .preference
        var domainLength = projectLength
        domainLength.id = UUID(); domainLength.scope = .work; domainLength.scopeID = nil
        domainLength.content = "工作回答详细一点"; domainLength.updatedAt = now.addingTimeInterval(30)
        let specific = reader.preferenceContext(question: "Atlas 项目", claims: [domainLength, projectLength], conversationID: nil, entities: [directive.scopeID!], now: now) ?? ""
        try expect(specific.contains("回答简洁") && !specific.contains("回答详细"), "更具体的项目约定应优先于较新但宽泛的工作偏好")
        let conversationID = UUID(), temporary = MemoryDirective.parse("记住：这次简洁一点", conversationID: conversationID)!
        try expect(temporary.scope == .conversation && temporary.scopeID == conversationID.uuidString, "记住前缀不能把这次要求变为永久要求")
    }
    private static func conflictsAndOverrides() async throws {
        let now = Date.now
        let source = capture("[聊天·自己] 我一直喜欢苹果。\n[聊天·自己] 我不喜欢苹果。", at: now.addingTimeInterval(-60))
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        try await store.addCapture(source); try await store.organizeMemory(force: true, now: now)
        let before = await store.snapshot()
        try expect(before.memoryKnowledge.claims.filter { $0.kind == .preference }.allSatisfy { $0.state == .conflicted }, "同语境矛盾的说法不能继续用于个性化")
        _ = try await store.remember(MemoryDirective.parse("记住：我喜欢苹果。")!, now: now)
        let after = await store.snapshot()
        try expect(after.memoryKnowledge.claims.filter { $0.kind == .preference && !$0.explicit }.allSatisfy { $0.state == .superseded }, "后来的明确说法应退出冲突旧版本")
        let id = UUID()
        _ = try await store.remember(MemoryDirective.parse("记住：以后工作周报详细一点")!, now: now)
        _ = try await store.remember(MemoryDirective.parse("这次简洁一点", conversationID: id)!, now: now)
        let current = await store.snapshot()
        let context = MemoryRetrievalEngine().preferenceContext(question: "工作周报", claims: current.memoryKnowledge.claims, conversationID: id, now: now) ?? ""
        try expect(context.contains("这次简洁") && !context.contains("周报详细"), "当前会话约定应覆盖同一表达维度的旧偏好，而不是同时给出矛盾要求")
    }
    private static func expiration() throws {
        let now = Date.now
        let source = capture("[聊天·自己] 我的目标是完成木刻基础练习。", at: now.addingTimeInterval(-86_400 * 31))
        let ledger = MemoryKnowledgeEngine().reconcile(RecallState(captures: [source]), force: true, now: now)
        try expect(ledger.claims.contains { $0.kind == .goal && $0.state == .expired && !$0.usable(at: now) }, "长期未更新的自动目标不能永久作为当前目标")
        let directive = MemoryDirective.parse("记住：今天回答简洁一点")!
        try expect(directive.validUntil != nil && directive.validUntil! > now && directive.validUntil! < now.addingTimeInterval(86_400 * 2), "明确的短期要求也必须有退出时间")
    }
    private static func legacyAndCorrection() async throws {
        let now = Date.now
        let record = capture("[聊天·自己] 我喜欢简洁的说明。", at: now)
        var state = RecallState(captures: [record]); state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state, force: true, now: now)
        state.memoryKnowledge.organizationVersion = 3
        if let i = state.memoryKnowledge.claims.firstIndex(where: { $0.kind == .preference }) { state.memoryKnowledge.claims[i].state = .active }
        let rebuilt = MemoryKnowledgeEngine().reconcile(state, now: now)
        try expect(rebuilt.organizationVersion == MemoryKnowledgeEngine.organizationVersion && !rebuilt.claims.contains { $0.kind == .preference && $0.usable(at: now) }, "规则升级必须重新检查旧的已激活偏好，不能只对新记录生效")
        let original = MemoryDirective(content: "简洁一点", key: "response-length")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "scopeExplicitlySet")
        let decoded = try JSONDecoder().decode(MemoryDirective.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(decoded.content == original.content && decoded.scopeExplicitlySet == nil, "新增范围元数据必须兼容旧记忆")
        let storage = try RecallStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.rootURL) }
        let store = try FileMemoryStore(storage: storage)
        _ = try await store.remember(original)
        let saved = await store.snapshot().memoryKnowledge.claims.first { $0.explicit }!
        try await store.retireMemory(id: saved.id)
        try await store.organizeMemory(force: true)
        let retired = await store.snapshot()
        try expect(!retired.memoryKnowledge.claims.contains { $0.id == saved.id && $0.usable() }, "重新整理不能复活停用的内容")
    }
}

private actor GroupingProbe: LLMResponding {
    enum Mode { case valid, rejectGroup, invalidID }
    let mode: Mode
    init(mode: Mode) { self.mode = mode }
    func answer(to request: LLMRequest) async throws -> LLMAnswer {
        let topics = try request.context.map { try JSONSerialization.jsonObject(with: Data($0.ocrText.utf8)) as! [String: Any] }
        let output: [String: Any]
        if request.purpose == .weeklySelection {
            output = ["topicIDs": [], "groups": [["title": "Atlas 发布流程页面改版", "topicIDs": mode == .invalidID ? ["invalid-topic"] : topics.map { $0["topicID"] as! String }]]]
        } else if request.purpose == .weeklyAudit {
            output = ["checks": topics.map { ["topicID": $0["topicID"]!, "supported": true, "correctAttribution": true,
                "preservesState": true, "coversKeyFacts": true, "sameMatter": mode != .rejectGroup] as [String: Any] }]
        } else {
            output = ["items": topics.map { ["topicID": $0["topicID"]!, "title": "Atlas 发布流程页面改版", "summary": "围绕发布页布局、历史列表和步骤导航明确了设计方案，尚未开始生产发布。", "evidenceIDs": $0["requiredEvidenceIDs"]!] }]
        }
        return LLMAnswer(content: String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self), citedCaptureIDs: [])
    }
}
