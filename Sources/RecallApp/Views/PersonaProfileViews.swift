import SwiftUI
import RecallKit

struct PersonaSummaryView: View {
    let state: RecallState
    let processing: Bool
    let onEvidence: () -> Void
    let onDismissMatch: () -> Void
    let onRetry: () -> Void
    private var traits: [PersonaTraitState] { state.confirmedPersonaTraits }
    private var failures: Int { state.personaRefreshJobs.filter { $0.status == .failed }.count }
    private var observedDays: Int { Set(state.personaTraitObservations.map(\.day)).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecallLocalization.both("近期行为观察", "Recent behavior observations")).font(.headline)
                    Text(status).font(.caption).foregroundStyle(RecallPalette.secondary)
                }
                Spacer()
                Button(RecallLocalization.both("查看依据与更正", "Evidence and corrections"), action: onEvidence).buttonStyle(.plain).foregroundStyle(RecallPalette.accent)
                    .accessibilityIdentifier("persona-evidence")
            }
            ForEach(Array(traits.prefix(3))) { trait in
                HStack(alignment: .firstTextBaseline) {
                    Text(RecallLocalization.text(trait.dimension.valueTitle(trait.value)))
                    Spacer()
                    Text(RecallLocalization.both("\(trait.observationDays) 个观察日", "\(trait.observationDays) observed days")).font(.caption).foregroundStyle(RecallPalette.secondary)
                }
            }
            if let match = state.personaMatch {
                HStack(alignment: .firstTextBaseline) {
                    Text(RecallLocalization.both("目前有些像「\(RecallLocalization.text(match.name))」", "Some resemblance to “\(RecallLocalization.text(match.name))”")).font(.caption).foregroundStyle(RecallPalette.secondary)
                    Spacer()
                    Button(RecallLocalization.both("这不像我", "This isn't quite me"), action: onDismissMatch).buttonStyle(.plain).font(.caption)
                }
            }
            if failures > 0 {
                HStack {
                    Text(RecallLocalization.both("\(failures) 天分析未完成，已有观察已保留。", "Analysis incomplete for \(failures) days. Existing observations are kept.")).font(.caption)
                    Button(RecallLocalization.both("重试", "Retry"), action: onRetry).buttonStyle(.plain).foregroundStyle(RecallPalette.accent)
                }
            }
            Text(RecallLocalization.both("根据近30天本人事项形成暂定观察，至少3个不同日期才会展示；当次要求和明确偏好优先。可在右上角菜单暂停或清空。", "Tentative observations use your own recent 30-day activity and require at least 3 distinct dates. Current requests and explicit preferences come first. Pause or clear from the menu above."))
                .font(.caption2).foregroundStyle(RecallPalette.secondary)
        }.recallSurface(padding: 18)
    }
    private var status: String {
        if !state.personaProfileSettings.enabled { return RecallLocalization.both("自动分析已停止", "Automatic analysis is stopped") }
        if !state.privacy.cloudUseEnabled || !state.llmConfiguration.hasCredential { return RecallLocalization.both("等待连接模型并允许脱敏文本处理，已有观察可在下方核对。", "Waiting for a connected model and text-processing permission. Existing evidence remains available.") }
        if processing { return RecallLocalization.both("正在后台分析，主动提问或生成回顾会优先处理。", "Analyzing in the background. Your questions and reviews take priority.") }
        if traits.isEmpty { return RecallLocalization.both("已积累 \(observedDays) 天有效观察，暂不足以形成稳定判断。", "Observations from \(observedDays) days; more independent evidence is needed.") }
        if !state.personaProfileSettings.personalizesResponses || !state.memoryKnowledgeSettings.referencesEnabled {
            return RecallLocalization.both("已暂停用于回答和建议", "Use in answers and suggestions is paused")
        }
        return RecallLocalization.both("相关回答会参考这些观察，你可以随时更正。", "Relevant answers may use these observations. You can correct them anytime.")
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
