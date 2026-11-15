import Foundation
import RecallKit

/// Covers the new automatic "关于我" persona-insight feature: local decay/merge math, verbatim-quote
/// evidence filtering, and the end-to-end store flow (pending queue drain, dismiss/resume, and
/// cleanup when the source daily review is deleted).
enum PersonaInsightVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }

    static func run() async throws {
        try traitMergeRequiresMultipleDaysBeforeConfirmed()
        try traitMergeSwitchesOnlyWhenNewSignalOutweighsDecay()
        try matchRequiresEnoughConfirmedAndSupportingDimensions()
        try observationsRejectUnverifiableOrUnknownEntries()
        try await endToEndRefreshDismissAndDeletionCleanup()
        print("PASS: 5 persona insight suites (decay merge, trait switching, archetype matching, evidence verification, store lifecycle)")
    }

    static func traitMergeRequiresMultipleDaysBeforeConfirmed() throws {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: .now)
        var traits: [PersonaTraitState] = []
        for offset in 0..<2 {
            let day = calendar.date(byAdding: .day, value: offset, to: day0)!
            let observation = PersonaTraitObservation(dimension: .workPace, value: "deep_focus", evidenceQuote: "连续三个小时没有切换任务", confidence: 0.7, day: day, sourceDailySummaryID: UUID())
            traits = PersonaProfileEngine.merge(existing: traits, with: [observation], now: day)
        }
        try expect(traits.first(where: { $0.dimension == .workPace })?.isConfirmed == false, "两天的观察不应被当作已确认的特征")
        let day2 = calendar.date(byAdding: .day, value: 2, to: day0)!
        let third = PersonaTraitObservation(dimension: .workPace, value: "deep_focus", evidenceQuote: "又一次整段时间专注在同一件事上", confidence: 0.7, day: day2, sourceDailySummaryID: UUID())
        traits = PersonaProfileEngine.merge(existing: traits, with: [third], now: day2)
        try expect(traits.first(where: { $0.dimension == .workPace })?.isConfirmed == true, "第三个独立观察日后应当确认该特征")
    }

    static func traitMergeSwitchesOnlyWhenNewSignalOutweighsDecay() throws {
        let calendar = Calendar.current
        let day0 = calendar.startOfDay(for: .now)
        var traits = PersonaProfileEngine.merge(existing: [], with: [
            PersonaTraitObservation(dimension: .decisionStyle, value: "decisive_fast", evidenceQuote: "当场拍板换掉原方案", confidence: 0.9, day: day0, sourceDailySummaryID: UUID())
        ], now: day0)
        let soon = calendar.date(byAdding: .day, value: 1, to: day0)!
        let weakContradiction = PersonaProfileEngine.merge(existing: traits, with: [
            PersonaTraitObservation(dimension: .decisionStyle, value: "cautious_verifying", evidenceQuote: "这次先征求了一下同事意见", confidence: 0.2, day: soon, sourceDailySummaryID: UUID())
        ], now: soon)
        try expect(weakContradiction.first(where: { $0.dimension == .decisionStyle })?.value == "decisive_fast", "弱证据不应立刻推翻仍有强度的旧判断")
        let muchLater = calendar.date(byAdding: .day, value: 30, to: day0)!
        let afterDecay = PersonaProfileEngine.merge(existing: traits, with: [
            PersonaTraitObservation(dimension: .decisionStyle, value: "cautious_verifying", evidenceQuote: "这一次反复和多个人确认后才决定", confidence: 0.6, day: muchLater, sourceDailySummaryID: UUID())
        ], now: muchLater)
        try expect(afterDecay.first(where: { $0.dimension == .decisionStyle })?.value == "cautious_verifying", "旧信号充分衰减后，新的独立证据应当能够切换判断")
        try expect(afterDecay.first(where: { $0.dimension == .decisionStyle })?.observationDays == 1, "切换取值后应当重新从第一天计数，避免立刻被视为已确认")
        traits = weakContradiction
    }

    static func matchRequiresEnoughConfirmedAndSupportingDimensions() throws {
        let now = Date.now
        func confirmed(_ dimension: PersonaDimension, _ value: String) -> PersonaTraitState {
            PersonaTraitState(dimension: dimension, value: value, strength: 0.8, observationDays: 5, evidenceIDs: [], updatedAt: now)
        }
        try expect(PersonaProfileEngine.match([confirmed(.decisionStyle, "cautious_verifying"), confirmed(.learningStyle, "systematic_research")], now: now) == nil,
            "少于三个已确认维度时不应给出任何形象匹配")
        let full = [
            confirmed(.decisionStyle, "cautious_verifying"), confirmed(.learningStyle, "systematic_research"),
            confirmed(.stressResponse, "breakdown_planning"), confirmed(.valueFocus, "quality"),
        ]
        let match = PersonaProfileEngine.match(full, now: now)
        try expect(match?.archetypeID == "meticulous-planner", "应当匹配到签名维度覆盖最多的形象")
        try expect(match?.supportingDimensions.count ?? 0 >= 2, "匹配结果应记录至少两个支撑维度")
        let excluded = PersonaProfileEngine.match(full, excludingArchetypeIDs: ["meticulous-planner"], now: now)
        try expect(excluded?.archetypeID != "meticulous-planner", "“这不像我”排除后不应再次返回同一个形象")
    }

    static func observationsRejectUnverifiableOrUnknownEntries() throws {
        let engine = PersonaInsightEngine()
        let sourceText = "今天把方案推翻重做了两次，临时决定直接上线。"
        let day = Date.now
        let valid = engine.observations(from: """
            {"traits":[{"dimension":"decisionStyle","value":"decisive_fast","evidence":"临时决定直接上线","confidence":0.6}]}
            """, sourceText: sourceText, day: day, dailySummaryID: UUID())
        try expect(valid.count == 1 && valid[0].evidenceQuote == "临时决定直接上线", "逐字可验证的证据应当被保留")

        let fabricated = engine.observations(from: """
            {"traits":[{"dimension":"decisionStyle","value":"decisive_fast","evidence":"原文中完全不存在的句子","confidence":0.6}]}
            """, sourceText: sourceText, day: day, dailySummaryID: UUID())
        try expect(fabricated.isEmpty, "无法在原文中逐字核实的证据必须被丢弃")

        let unknownDimension = engine.observations(from: """
            {"traits":[{"dimension":"iqLevel","value":"high","evidence":"临时决定直接上线","confidence":0.9}]}
            """, sourceText: sourceText, day: day, dailySummaryID: UUID())
        try expect(unknownDimension.isEmpty, "不在允许目录中的维度必须被丢弃")

        let duplicateDimensions = engine.observations(from: """
            {"traits":[
              {"dimension":"decisionStyle","value":"decisive_fast","evidence":"临时决定直接上线","confidence":0.6},
              {"dimension":"decisionStyle","value":"cautious_verifying","evidence":"今天把方案推翻重做了两次","confidence":0.6}
            ]}
            """, sourceText: sourceText, day: day, dailySummaryID: UUID())
        try expect(duplicateDimensions.count == 1, "同一维度不应被重复输出")
    }

    actor FixedPersonaModel: LLMResponding {
        var requests: [LLMRequest] = []
        func log() -> [LLMRequest] { requests }
        func answer(to request: LLMRequest) async throws -> LLMAnswer {
            requests.append(request)
            guard request.purpose == .personaInsight, request.context.count == 1 else {
                throw Failure(errorDescription: "个人特征提炼请求未按预期只携带当天回顾文本")
            }
            return LLMAnswer(content: """
                {"traits":[{"dimension":"workPace","value":"deep_focus","evidence":"保留本人明确的未完成承诺","confidence":0.7}]}
                """, citedCaptureIDs: [])
        }
    }

    static func endToEndRefreshDismissAndDeletionCleanup() async throws {
        let f = try await ModelReviewVerification.fixture(raw: true, text: "[聊天·自己] Atlas 的边界验证交给我，明早给评审。")
        defer { try? FileManager.default.removeItem(at: f.storage.rootURL) }
        let outcome = try await f.store.generateDirectDailyReview(day: f.records[0].createdAt, period: f.period, responder: DirectDailyReviewVerification.Model("action"))
        let summaryID = outcome.summary.id
        try expect(outcome.summary.todos.count == 1, "测试前置条件未成立：生成的回顾应当含有一条归属本人的行动项")
        var state = await f.store.snapshot()
        try expect(state.pendingPersonaRefresh == [summaryID], "每日回顾保存后应当把当天加入个人特征提炼队列")

        let model = FixedPersonaModel()
        let didWork = try await f.store.refreshPersonaProfile(responder: model)
        try expect(didWork, "队列中有待处理的日期时应当返回已处理")
        state = await f.store.snapshot()
        try expect(state.pendingPersonaRefresh.isEmpty, "处理后的日期应当从队列中移除")
        try expect(state.personaTraitObservations.contains { $0.dimension == .workPace }, "校验通过的观察应当被保留")

        try await f.store.dismissPersonaTrait(.workPace)
        state = await f.store.snapshot()
        try expect(!state.personaTraits.contains { $0.dimension == .workPace }, "停用后不应再展示该维度的判断")
        try expect(state.dismissedPersonaDimensions.contains(.workPace), "停用的维度应当被记录，避免之后又被悄悄恢复")

        try await f.store.resumePersonaTrait(.workPace)
        state = await f.store.snapshot()
        try expect(!state.dismissedPersonaDimensions.contains(.workPace), "恢复后不应再出现在停用列表中")

        try await f.store.deleteDailySummary(id: summaryID)
        state = await f.store.snapshot()
        try expect(!state.personaTraitObservations.contains { $0.sourceDailySummaryID == summaryID }, "删除每日回顾后应清除其派生出的个人特征观察")
        try expect(!state.personaTraits.contains { $0.dimension == .workPace }, "唯一来源的回顾被删除后，该维度判断不应继续存在")
    }
}
