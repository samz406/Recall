import SwiftUI
import RecallKit

struct PersonaSummaryView: View {
    let state: RecallState
    let processing: Bool
    let onEvidence: () -> Void
    let onKeep: (PersonaDimension) -> Void
    let onDismiss: (PersonaDimension) -> Void
    let onRetry: () -> Void
    private var traits: [PersonaTraitState] { state.confirmedPersonaTraits }
    /// Habits whose guidance is already an explicit memory add nothing; only unconfirmed ones are listed.
    private var pending: [PersonaTraitState] {
        traits.filter { trait in
            guard let guidance = trait.responseGuidance else { return true }
            return !explicit.contains { $0.contains(guidance) }
        }
    }
    private var mixed: [PersonaTraitState] { state.mixedPersonaTraits }
    private var failures: Int { state.personaRefreshJobs.filter { $0.status == .failed }.count }
    private var observedDays: Int { Set(state.personaTraitObservations.map(\.day)).count }
    /// Explicit preferences the user already kept, so the same observation is not offered again.
    private var explicit: [String] {
        state.memoryKnowledge.claims.filter { $0.kind.isPersonal && $0.usable() }.map(\.content)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecallLocalization.both("Recall 观察到的习惯", "Habits Recall noticed")).font(.headline)
                    Text(status).font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(RecallLocalization.both("查看依据", "View evidence"), action: onEvidence)
                    .buttonStyle(.plain).font(.subheadline).foregroundStyle(RecallPalette.accent).fixedSize()
                    .accessibilityIdentifier("persona-evidence")
            }.padding(16)
            ForEach(Array(pending.prefix(3))) { trait in
                Divider().padding(.horizontal, 16)
                row(trait).padding(16)
            }
            if !traits.isEmpty && pending.isEmpty {
                Divider().padding(.horizontal, 16)
                Text(RecallLocalization.both("目前观察到的习惯都已在上方“已记住”里，没有需要你确认的新内容。",
                                             "Everything Recall noticed is already in “Remembered” above. Nothing new to confirm."))
                    .font(.callout).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true).padding(16)
            }
            if failures > 0 {
                Divider().padding(.horizontal, 16)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(RecallLocalization.both("\(failures) 天分析未完成，已有观察已保留。", "Analysis incomplete for \(failures) days. Existing observations are kept."))
                        .font(.caption).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    Button(RecallLocalization.both("重试", "Retry"), action: onRetry).buttonStyle(.plain).foregroundStyle(RecallPalette.accent).fixedSize()
                }.padding(16)
            }
            if !traits.isEmpty {
                Divider().padding(.horizontal, 16)
                Text(RecallLocalization.both("仅影响“问一问”的回答方式；你明确保存的内容优先。",
                                             "Only shapes how Ask answers. Your explicit preferences come first."))
                    .font(.caption2).foregroundStyle(RecallPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.vertical, 12)
                    .help(RecallLocalization.both("暂定观察：近 30 天里至少 3 天一致才会出现。不进入回顾；当次要求和你明确记住的内容优先。可在右上角菜单暂停或清空。",
                                                  "Tentative: shown after at least 3 consistent days in the last 30. Never used in reviews. Current requests and explicit preferences come first. Pause or clear from the menu above."))
            }
        }.recallSurface(padding: 0)
    }
    private func row(_ trait: PersonaTraitState) -> some View {
        let guidance = trait.responseGuidance
        let kept = guidance.map { text in explicit.contains { $0.contains(text) } } ?? false
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        traitTitle(trait)
                        support(trait)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        traitTitle(trait)
                        support(trait)
                    }
                }
                if let guidance {
                    Text(RecallLocalization.both("回答你时会：\(guidance)", "Answers will: \(guidance)"))
                        .font(.caption).foregroundStyle(RecallPalette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            traitActions(trait, kept: kept, hasGuidance: guidance != nil).fixedSize()
        }
    }
    private func traitTitle(_ trait: PersonaTraitState) -> some View {
        Text(RecallLocalization.text(trait.dimension.valueTitle(trait.value)))
            .font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
    }
    private func support(_ trait: PersonaTraitState) -> some View {
        Text(RecallLocalization.both("近 30 天有 \(trait.observationDays) 天体现", "Seen on \(trait.observationDays) of the last 30 days"))
            .font(.caption2).foregroundStyle(RecallPalette.secondary).fixedSize()
    }
    private func traitActions(_ trait: PersonaTraitState, kept: Bool, hasGuidance: Bool) -> some View {
        HStack(spacing: 8) {
            if kept {
                Label(RecallLocalization.both("已记住", "Remembered"), systemImage: "checkmark").font(.caption).foregroundStyle(RecallPalette.secondary)
            } else {
                if hasGuidance {
                    Button(RecallLocalization.both("记住", "Remember")) { onKeep(trait.dimension) }
                        .controlSize(.small)
                        .help(RecallLocalization.both("保存为你的明确偏好，之后可在上方修改或停用。", "Save as an explicit preference. You can edit or retire it above."))
                }
                Button(RecallLocalization.both("不准确", "Not right")) { onDismiss(trait.dimension) }
                    .controlSize(.small)
                    .help(RecallLocalization.both("不再推断“\(RecallLocalization.text(trait.dimension.title))”，可在右上角菜单恢复。",
                                                  "Stop inferring “\(RecallLocalization.text(trait.dimension.title))”. Restore it from the menu above."))
            }
        }
    }
    private var status: String {
        if !state.personaProfileSettings.enabled { return RecallLocalization.both("自动分析已停止", "Automatic analysis is stopped") }
        if !state.privacy.cloudUseEnabled || !state.llmConfiguration.hasCredential { return RecallLocalization.both("等待连接模型并允许脱敏文本处理，已有观察可在依据中核对。", "Waiting for a connected model and text-processing permission. Existing evidence remains available.") }
        if processing { return RecallLocalization.both("正在后台分析，主动提问或生成回顾会优先处理。", "Analyzing in the background. Your questions and reviews take priority.") }
        if traits.isEmpty && !mixed.isEmpty { return RecallLocalization.both("近期表现不一，暂不形成判断。", "Recent days point in different directions, so no judgment yet.") }
        if traits.isEmpty { return RecallLocalization.both("已积累 \(observedDays) 天观察，还不足以形成判断。", "Observations from \(observedDays) days; more independent evidence is needed.") }
        if !state.personaProfileSettings.personalizesResponses || !state.memoryKnowledgeSettings.referencesEnabled {
            return RecallLocalization.both("已暂停用于回答", "Paused for answers")
        }
        return RecallLocalization.both("根据你的每日回顾推断，不对可以直接标记。", "Inferred from your daily reviews. Mark anything that's wrong.")
    }
}

struct PersonaEvidenceSheet: View {
    @EnvironmentObject private var model: RecallAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: CaptureRecord?
    private var observations: [PersonaTraitObservation] { model.state.personaTraitObservations.sorted { $0.day > $1.day } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(RecallLocalization.both("观察与依据", "Observations and evidence")).font(.title2.bold())
                Spacer(); Button(RecallLocalization.both("关闭", "Close")) { dismiss() }
            }
            Text(RecallLocalization.both("这些是暂定的行为观察。引用能说明依据来自哪里，不能单凭引用证明判断正确。归属不对或依据不足时可逐条撤回。", "These are tentative observations. Quotes show their source, not proof that an interpretation is correct. Retract evidence that is misattributed or insufficient."))
                .font(.caption).foregroundStyle(RecallPalette.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.state.personaRefreshJobs.filter { $0.status == .failed }) { job in
                        VStack(alignment: .leading, spacing: 6) {
                            if let summary = model.state.dailySummaries.first(where: { $0.id == job.summaryID }) {
                                Text(summary.day.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                            }
                            Text(job.failure == "format"
                                ? RecallLocalization.both("模型返回格式或依据未通过校验。", "The response format or evidence did not pass validation.")
                                : RecallLocalization.both("模型服务暂未完成请求，可能是网络或超时。", "The model request did not finish, possibly due to connectivity or timeout."))
                            HStack {
                                Text(RecallLocalization.both("已尝试 \(job.attempts)/3 次；已有观察保留。", "Attempted \(job.attempts)/3 times. Existing observations are kept.")).font(.caption)
                                Spacer()
                                Button(RecallLocalization.both("重试未完成的分析", "Retry incomplete analysis")) { Task { await model.updatePersonaProfile(.retry) } }
                                    .disabled(model.isUpdatingPersonaProfile)
                            }
                        }.recallSurface(padding: 16)
                    }
                    if observations.isEmpty {
                        Text(RecallLocalization.both("还没有有效观察。新回顾或重新分析后会显示有依据的内容；没有足够证据时保留为空。", "No valid observations yet. New or reanalyzed reviews can supply evidence; insufficient evidence leaves this empty."))
                            .foregroundStyle(RecallPalette.secondary)
                    }
                    ForEach(observations) { observation in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(RecallLocalization.text(observation.dimension.valueTitle(observation.value))).font(.headline)
                                Spacer(); Text(observation.day.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                            }
                            Text(observation.evidenceQuote).textSelection(.enabled)
                            HStack(spacing: 16) {
                                Button(RecallLocalization.both("查看当天回顾", "Open daily review")) {
                                    model.destination = .daily(observation.sourceDailySummaryID); dismiss()
                                }.buttonStyle(.plain).foregroundStyle(RecallPalette.accent)
                                Menu(RecallLocalization.both("查看来源", "View source")) {
                                    ForEach(sources(for: observation)) { record in
                                        Button(record.sourceAppName ?? RecallLocalization.both("原始记录", "Source record")) { source = record }
                                    }
                                }.fixedSize()
                                Spacer()
                                Button(RecallLocalization.both("依据不足，撤回这条", "Insufficient evidence — retract")) {
                                    Task { await model.updatePersonaProfile(.reject([observation.id])) }
                                }.buttonStyle(.plain).disabled(model.isUpdatingPersonaProfile)
                                Menu {
                                    Button(RecallLocalization.both("不再判断这个维度", "Stop inferring this dimension")) { model.dismissPersonaTrait(observation.dimension) }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            }.font(.caption)
                            if model.state.dismissedPersonaDimensions.contains(observation.dimension) {
                                Text(RecallLocalization.both("这个维度已停止使用，可在“关于我”的菜单恢复。", "This dimension is stopped. Restore it from the About me menu.")).font(.caption).foregroundStyle(RecallPalette.secondary)
                            }
                        }.recallSurface(padding: 16)
                    }
                }
            }
        }.padding(24).frame(minWidth: 660, idealWidth: 760, minHeight: 460, idealHeight: 620)
        .sheet(item: $source) { CaptureDetailSheet(capture: $0).environmentObject(model) }
    }
    private func sources(for observation: PersonaTraitObservation) -> [CaptureRecord] {
        guard let summary = model.state.dailySummaries.first(where: { $0.id == observation.sourceDailySummaryID }),
              let proof = PersonaInsightEngine().evidence(for: summary).first(where: { $0.id == observation.evidenceID }) else { return [] }
        let ids = Set(proof.sourceIDs)
        return model.state.captures.filter { ids.contains($0.id) }
    }
}
