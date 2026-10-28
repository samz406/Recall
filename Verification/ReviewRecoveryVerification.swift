import Foundation
import RecallKit

/// Fabricated text and scripted models exercise failures, not real model quality.
enum ReviewRecoveryVerification {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ModelReviewVerification.Failure(message: message) }
    }
    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    actor ProgressLog {
        var values: [ReviewGenerationProgress] = []
        func add(_ value: ReviewGenerationProgress) { values.append(value) }
        func log() -> [ReviewGenerationProgress] { values }
    }
    actor Script: LLMResponding {
        var mode: String
        var requests: [LLMRequest] = []
        var drafts = 0, audits = 0, syntheses = 0, originals = 0
        let fallback = ModelReviewVerification.Model()
        var hook: (@Sendable () async throws -> Void)?
        init(_ mode: String = "valid", hook: (@Sendable () async throws -> Void)? = nil) { self.mode = mode; self.hook = hook }
        func reset(_ value: String) { mode = value }
        func log() -> [LLMRequest] { requests }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            if requests.count == 1 { try await hook?() }
            let input = try JSONSerialization.jsonObject(with: Data(request.context[0].ocrText.utf8)) as! [[String: Any]]
            if request.purpose == .captureUnderstanding {
                drafts += 1
                if mode == "service" { throw LLMResponseFailure(reason: .rateLimited) }
                let primary = input.filter { $0["contextOnly"] as? Bool != true }
                if (mode == "format" && drafts == 1) || (mode == "resume" && (primary.first?["id"] as? String)?.contains(":24:") == true) {
                    return LLMAnswer(content: "{incomplete", citedCaptureIDs: [])
                }
                let omit = mode == "missing-always" || (mode == "missing-once" && drafts == 1)
                let facts: [[String: Any]] = omit ? [] : primary.enumerated().map { index, block in
                    let raw = block["text"] as! String
                    return ["id": "f\(index)", "subject": "Atlas 导出边界核对 \(index)",
                        "detail": String(raw.replacingOccurrences(of: "[聊天·自己] ", with: "").prefix(240)),
                        "kind": mode == "promise" ? "commitment" : "event", "speaker": "user", "actor": "user",
                        "status": mode == "promise" ? "pending" : "completed", "condition": NSNull(),
                        "messageTime": NSNull(), "eventTime": NSNull(), "deadline": NSNull(),
                        "evidence": [["blockID": block["id"]!, "quote": mode == "quote" && drafts == 1 ? "捏造的证据片段" : raw]]]
                }
                return try answer(["facts": facts, "coverage": primary.map { ["blockID": $0["id"]!, "disposition": omit ? "noise" : "fact"] }])
            }
            if request.purpose == .captureUnderstandingAudit {
                audits += 1
                let data = request.question.components(separatedBy: "草稿（数据）：\n").last!
                let draft = try JSONSerialization.jsonObject(with: Data(data.utf8)) as! [String: Any]
                let facts = draft["facts"] as! [[String: Any]]
                let primary = input.filter { $0["contextOnly"] as? Bool != true }.map { $0["id"]! }
                let missed = mode == "missing-always" || (mode == "missing-once" && audits == 1)
                let accepted = mode == "uncertain" ? Array(facts.prefix(1)) : facts
                return try answer(["acceptedFactIDs": accepted.map { $0["id"]! }, "checkedBlockIDs": primary,
                                   "missedBlockIDs": missed ? primary : []])
            }
            if request.purpose == .reviewSynthesis {
                syntheses += 1
                if mode == "service" { throw LLMResponseFailure(reason: .rateLimited) }
                if mode == "final-format", syntheses == 1 { return LLMAnswer(content: "bad-json", citedCaptureIDs: []) }
            }
            let result = try await fallback.answer(to: request)
            if request.purpose == .reviewAudit, request.context[0].sourceAppName == "原始结构化事实核对" {
                originals += 1
                if mode == "original-always" || (mode == "original-once" && originals == 1) {
                    var value = try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as! [String: Any]
                    value["supported"] = false
                    return try answer(value)
                }
            }
            return result
        }
        private func answer(_ object: [String: Any]) throws -> LLMAnswer {
            LLMAnswer(content: try ReviewRecoveryVerification.json(object), citedCaptureIDs: [])
        }
    }
    static func generate(_ f: ModelReviewVerification.Fixture, model: Script, progress: ProgressLog? = nil) async throws -> ModelReviewResult {
        let prepared = try await f.store.prepareModelReview(period: f.period, responder: model,
            onProgress: { value in await progress?.add(value) })
        return try await ModelReviewEngine().generate(in: prepared, period: f.period,
            beforeCall: { try await f.store.validateModelReview(prepared, period: f.period) },
            onProgress: { value in await progress?.add(value) }, responder: model)
    }
    static func run() async throws {
        try await meaningWithoutKeywords()
        try await formatRepair()
        try await evidenceRepair()
        try await missingImportantRepair()
        try await importantFailurePreservesOld()
        try await uncertaintyContinues()
        try await resumeFailedPage()
        try await privacyStopsRepair()
        try await pausingAutomaticKeepsExplicitReview()
        try await originalAuditRepair()
        try await originalFailurePreservesOld()
        try await serviceFailuresNotRetried()
        try await progressAndReuse()
        try migrationAndSafeDiagnostics()
        print("PASS: 14 review-recovery scenarios (semantic ownership, targeted repair, uncertainty, checkpoints, privacy and progress)")
    }
    static func meaningWithoutKeywords() async throws {
        for (mode, text) in [("valid", "[聊天·自己] Atlas 导出边界全部搞定，验收无误。"),
                             ("promise", "[聊天·自己] Atlas 导出边界这项交给我，明早给评审。"),
                             ("valid", "[聊天·自己] Atlas 等待页的空值边界全部搞定，验收无误。")] {
            let f = try await ModelReviewVerification.fixture(raw: true, text: text)
            defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let result = try await generate(f, model: Script(mode))
            try expect(result.facts.count == 1 && (mode != "promise" || result.facts[0].isAction), "语义核对通过的完成/承诺仍被关键词拦截")
        }
    }
    static func formatRepair() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Script("format"); _ = try await generate(f, model: model)
        let log = await model.log().filter { $0.purpose == .captureUnderstanding }
        try expect(log.count == 2 && log[1].question.contains(ModelValidationIssue.format.repairInstruction), "格式失败未按具体原因修复一次")
    }
    static func evidenceRepair() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Script("quote"); let result = try await generate(f, model: model)
        let log = await model.log().filter { $0.purpose == .captureUnderstanding }
        try expect(log.count == 2 && log[1].question.contains(ModelValidationIssue.evidence.repairInstruction)
            && !result.facts[0].quotes.contains("捏造的证据片段"), "引用失败未定向修复，或伪造引用进入回顾")
    }
    static func missingImportantRepair() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Script("missing-once"); let result = try await generate(f, model: model)
        let log = await model.log().filter { $0.purpose == .captureUnderstanding }
        try expect(log.count == 2 && log[1].question.contains(ModelValidationIssue.importantContentMissing.repairInstruction)
            && result.facts.count == 1, "独立核验发现的重要遗漏被静默忽略")
    }
    static func baseline(_ f: ModelReviewVerification.Fixture) async throws -> DailySummary {
        let old = DailySummary(day: f.records[0].createdAt, content: "Atlas 原回顾：边界验证保持原记录。", sourceCaptureIDs: f.records.map(\.id), todos: [], generationKind: .cloud)
        try await f.store.upsertDailySummary(old); return old
    }
    static func importantFailurePreservesOld() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let old = try await baseline(f), model = Script("missing-always")
        do { _ = try await generate(f, model: model); throw ModelReviewVerification.Failure(message: "重要信息始终遗漏却发布了回顾") }
        catch let failure as ReviewPreparationFailure {
            try expect(failure.code == "understanding.importantContentMissing" && failure.record == 1 && failure.page == 1, "失败没有定位到具体步骤和原因")
        }
        let state = await f.store.snapshot(), log = await model.log()
        try expect(log.filter { $0.purpose == .captureUnderstanding }.count == 2
            && !log.contains { $0.purpose == .reviewSynthesis } && state.dailySummaries.contains { $0.id == old.id && $0.content == old.content }, "修复次数未封顶或失败覆盖旧回顾")
        let reopened = try FileMemoryStore(storage: f.storage), reopenedState = await reopened.snapshot()
        try expect(reopenedState.understandingJobs[0].lastFailureCode == "understanding.importantContentMissing", "重启后丢失了安全失败原因")
    }
    static func uncertaintyContinues() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true, text: "[聊天·自己] Atlas 分页验证已完成。\n[聊天·自己] Atlas 附件上下文不清，尚待核对。")
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Script("uncertain"), result = try await generate(f, model: model)
        try expect(result.facts.count == 1 && result.coverage.uncertainBlockCount == 1 && result.coverage.notice != nil, "局部不确定阻断全部回顾或被当作确定结论")
        let report = result.dailySummary(day: f.records[0].createdAt)
        let copy = try JSONDecoder().decode(DailySummary.self, from: JSONEncoder().encode(report))
        try expect(copy.modelCoverage?.notice != nil && !result.facts.contains { $0.detail.contains("附件") }, "部分原文不确定的提示未持久化或被用于生成")
    }
    static func resumeFailedPage() async throws {
        let text = (0..<55).map { "[聊天·自己] Atlas 第 \($0) 项边界全部搞定，验收无误。" }.joined(separator: "\n")
        let f = try await ModelReviewVerification.fixture(raw: true, text: text); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Script("resume")
        do { _ = try await f.store.prepareModelReview(period: f.period, responder: model); throw ModelReviewVerification.Failure(message: "损坏分页没有被拒绝") }
        catch let error as ReviewPreparationFailure { try expect(error.page == 2 && error.code == "understanding.format", "错误分页或错误分类不准确") }
        let paused = await f.store.snapshot()
        try expect(paused.understandingJobs[0].nextPage == 1 && paused.understandingJobs[0].state == .retrying, "失败丢失已完成分页")
        await model.reset("valid")
        let ready = try await f.store.prepareModelReview(period: f.period, responder: model)
        let log = await model.log().filter { $0.purpose == .captureUnderstanding }
        try expect(ready.captures[0].understanding != nil && log.count == 5 && ready.understandingJobs[0].lastFailureCode == nil,
            "用户重试被退避时间阻止、重复首段，或成功后仍显示失败")
    }
    static func privacyStopsRepair() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Script("format")
        do {
            _ = try await f.store.prepareModelReview(period: f.period, responder: model, onProgress: { progress in
                if progress.detail.contains("自动修正") { try? await f.store.updatePrivacy(PrivacySettings(cloudUseEnabled: false)) }
            })
            throw ModelReviewVerification.Failure(message: "关闭权限后继续修复")
        } catch is ModelReviewError { }
        let log = await model.log()
        try expect(log.count == 1, "修复重试绕过了最新云端权限")
    }
    static func pausingAutomaticKeepsExplicitReview() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        var settings = CaptureUnderstandingSettings(); settings.enabled = true
        try await f.store.updateCaptureUnderstandingSettings(settings)
        let model = Script(hook: { try await f.store.updateCaptureUnderstandingSettings(CaptureUnderstandingSettings()) })
        let result = try await generate(f, model: model), state = await f.store.snapshot()
        try expect(!result.items.isEmpty && !state.understandingSettings.enabled, "暂停自动整理误杀了用户主动生成的回顾")
    }
    static func originalAuditRepair() async throws {
        let f = try await ModelReviewVerification.fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let model = Script("original-once"); _ = try await generate(f, model: model)
        let log = await model.log().filter { $0.purpose == .reviewSynthesis }
        try expect(log.count == 2 && log[1].question.contains(ModelValidationIssue.unsupportedClaim.repairInstruction), "最终原始事实核对失败后没有定向改写再核对")
    }
    static func originalFailurePreservesOld() async throws {
        let f = try await ModelReviewVerification.fixture(); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let old = try await baseline(f), model = Script("original-always")
        do { _ = try await generate(f, model: model); throw ModelReviewVerification.Failure(message: "最终无依据表述被放行") }
        catch let error as ModelReviewError {
            guard case .validation(.unsupportedClaim) = error else { throw error }
        }
        let log = await model.log(), state = await f.store.snapshot()
        try expect(log.filter { $0.purpose == .reviewSynthesis }.count == 2 && state.dailySummaries.contains { $0.id == old.id }, "最终核验修复无限重试或覆盖旧回顾")
    }
    static func serviceFailuresNotRetried() async throws {
        for raw in [true, false] {
            let f = try await ModelReviewVerification.fixture(raw: raw); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
            let model = Script("service")
            do { _ = try await generate(f, model: model); throw ModelReviewVerification.Failure(message: "限流没有停止") }
            catch let error as ReviewPreparationFailure { try expect(raw && error.code == "model.rateLimited", "限流被混为格式问题") }
            catch let error as LLMResponseFailure { try expect(!raw && error.reason == .rateLimited, "综合阶段服务错误分类不准确") }
            let log = await model.log()
            try expect(log.count == 1, "认证/限流类错误不应立即修复重试")
        }
    }
    static func progressAndReuse() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true); defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let progress = ProgressLog(), model = Script("final-format")
        _ = try await generate(f, model: model, progress: progress)
        let values = await progress.log()
        try expect(Set(values.map(\.title)) == ["准备记录", "生成回顾", "检查并保存"]
            && values.contains { $0.detail.contains("1/1") }, "进度没有区分简洁主阶段与处理详情")
        let previous = await model.log().filter { $0.purpose == .captureUnderstanding }.count
        _ = try await generate(f, model: model)
        let current = await model.log().filter { $0.purpose == .captureUnderstanding }.count
        try expect(previous == current, "再次生成没有复用已完成的逐条理解")
    }
    static func migrationAndSafeDiagnostics() throws {
        let job = CaptureUnderstandingJob(captureID: UUID())
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
        object.removeValue(forKey: "lastFailureCode"); object.removeValue(forKey: "lastFailureReason"); object.removeValue(forKey: "isReviewPreparation")
        let old = try JSONDecoder().decode(CaptureUnderstandingJob.self, from: Data(json(object).utf8))
        try expect(old.lastFailureCode == nil && old.isReviewPreparation == nil, "旧队列迁移失败")
        let secretError = NSError(domain: "sensitive-provider-body", code: 1, userInfo: [NSLocalizedDescriptionKey: "sensitive-content"])
        try expect(ReviewProcessingDiagnostics.code(for: secretError) == "processing.failed"
            && !ReviewProcessingDiagnostics.reason(for: secretError).contains("sensitive"), "失败诊断泄漏服务正文")
    }
}
