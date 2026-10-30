import Foundation

public struct ReminderDiscoveryRun: Sendable {
    public var eligibleRecords: Int
    public var analyzedRecords: Int
    public var added: Int
    public var excludedRecords: Int
    public var unchangedRecords: Int
}

public extension FileMemoryStore {
    func setAutomaticReminderDiscovery(_ enabled: Bool) throws {
        let before = state
        state.reminderLearningProfile.automaticDiscovery = enabled
        do { try persist() } catch { state = before; throw error }
    }

    /// Successful groups advance the checkpoint; failed groups never remove earlier candidates.
    func discoverRemindersUsingModel(force: Bool = false, automatic: Bool = false,
                                    responder: any LLMResponding, now: Date = .now,
                                    progress: @escaping @Sendable (ReminderDiscoveryProgress) async -> Void = { _ in }) async throws -> ReminderDiscoveryRun {
        let config = state.llmConfiguration
        guard state.privacy.cloudUseEnabled, config.provider != .localOnly, !config.apiKey.isEmpty,
              !automatic || state.reminderLearningProfile.automaticDiscovery == true else { throw ReminderDiscoveryError.unavailable }
        let privacy = state.privacy, engine = ModelReminderDiscovery()
        let plan = engine.plan(in: state, force: force, now: now)
        let startedAt = Date.now, runKnownIDs = Set(state.reminders.map(\.id))
        var completed = 0, added = 0
        do {
            for group in plan.groups {
                try Task.checkCancellation()
                let ids = Set(group.map(\.id))
                let context = engine.contextSources(for: group, in: state)
                let contextVersions = Dictionary(uniqueKeysWithValues: context.map { ($0.id.uuidString, MemoryKnowledgeEngine.version(of: $0)) })
                let inputIDs = ids.union(context.map(\.id))
                let versions = plan.versions.merging(contextVersions) { _, current in current }
                try validateReminderModelInput(inputIDs, versions: versions, configuration: config, privacy: privacy, automatic: automatic)
                let snapshot = state.correctedForAnalysis(), done = completed
                let result = try await engine.analyze(group, in: snapshot, responder: responder, beforeCall: {
                    try Task.checkCancellation()
                    try await self.validateReminderModelInput(inputIDs, versions: versions, configuration: config, privacy: privacy, automatic: automatic)
                }, progress: { phase in
                    await progress(ReminderDiscoveryProgress(completedRecords: done, totalRecords: plan.recordCount, phase: phase))
                })
                try Task.checkCancellation()
                try validateReminderModelInput(inputIDs, versions: versions, configuration: config, privacy: privacy, automatic: automatic)
                let before = state
                do {
                    var checkpoint = state.reminderDiscoveryCheckpoint
                    if checkpoint.extractorVersion != ModelReminderDiscovery.version { checkpoint.processedCaptureHashes = [:] }
                    for id in ids { checkpoint.processedCaptureHashes[id.uuidString] = plan.versions[id.uuidString] }
                    checkpoint.extractorVersion = ModelReminderDiscovery.version
                    checkpoint.lastRunAt = .now; checkpoint.lastAttemptAt = .now; checkpoint.failureReason = nil
                    checkpoint.excludedRecordCount = plan.excludedCount; checkpoint.unchangedRecordCount = plan.unchangedCount
                    checkpoint.analyzedRecordCount = completed + group.count
                    let safe = state.correctedForAnalysis()
                    for (id, status) in result.resolutions {
                        guard let i = state.reminders.firstIndex(where: {
                            $0.id == id && $0.status == .proposed && $0.origin == .discovered && $0.updatedAt <= startedAt
                        }), state.reminders[i].sourceCaptureIDs.allSatisfy({ sourceID in
                            safe.captures.first(where: { $0.id == sourceID }).map { ModelReminderDiscovery.eligible($0, in: state) } == true
                        }) else { continue }
                        state.reminders[i].status = status; state.reminders[i].closedAt = .now; state.reminders[i].updatedAt = .now
                        let proofs = result.resolutionEvidence[id] ?? []
                        let sourceIDs = proofs.compactMap { UUID(uuidString: String($0.blockID.prefix(36))) }
                        state.reminders[i].sourceCaptureIDs = Array(Set(state.reminders[i].sourceCaptureIDs + sourceIDs))
                        state.reminders[i].analysis = ReminderAnalysis(version: ModelReminderDiscovery.version,
                            basis: status == .completed ? "后续记录显示已完成" : (status == .cancelled ? "后续记录显示已取消" : "核对后不属于用户待办"),
                            deadlineText: state.reminders[i].analysis?.deadlineText, evidence: proofs)

                        if status == .completed { state.reminders[i].completedAt = .now }
                        if status == .dismissed { state.reminders[i].dismissedUntil = Date.now.addingTimeInterval(30 * 86_400) }
                    }
                    let candidates = result.candidates.filter { candidate in
                        guard !SummaryFeedbackLearning.rejectsAction(title: candidate.title, sourceIDs: candidate.sourceCaptureIDs, in: state) else { return false }
                        if let old = state.reminders.first(where: { $0.id == candidate.id }) {
                            return old.sourceCaptureIDs.allSatisfy { sourceID in safe.captures.first(where: { $0.id == sourceID }).map { ModelReminderDiscovery.eligible($0, in: state) } == true }
                        }
                        return true
                    }
                    _ = try applyReminderDiscovery(candidates: candidates, checkpoint: checkpoint,
                        revalidatedSourceIDs: ids.subtracting(result.uncertainSourceIDs), startedAt: startedAt,
                        runKnownIDs: runKnownIDs, eligibleCount: plan.eligibleCount, additionalSourceVersions: contextVersions)
                    added = state.reminderDiscoveryCheckpoint.discoveredCount
                } catch { state = before; throw error }
                completed += group.count
                await progress(ReminderDiscoveryProgress(completedRecords: completed, totalRecords: plan.recordCount, phase: "已保存核对结果"))
            }
            if plan.groups.isEmpty {
                let before = state
                state.reminderDiscoveryCheckpoint.lastAttemptAt = .now
                state.reminderDiscoveryCheckpoint.failureReason = nil
                state.reminderDiscoveryCheckpoint.analyzedRecordCount = 0
                state.reminderDiscoveryCheckpoint.discoveredCount = 0
                state.reminderDiscoveryCheckpoint.eligibleRecordCount = plan.eligibleCount
                state.reminderDiscoveryCheckpoint.excludedRecordCount = plan.excludedCount
                state.reminderDiscoveryCheckpoint.unchangedRecordCount = plan.unchangedCount
                do { try persist() } catch { state = before; throw error }
            }
            return ReminderDiscoveryRun(eligibleRecords: plan.eligibleCount, analyzedRecords: completed, added: added,
                excludedRecords: plan.excludedCount, unchangedRecords: plan.unchangedCount)
        } catch {
            let safeReason = ModelCallCancellation.isCancellation(error) ? "本次已停止，已完成的分析已保存。"
                : ((error as? ReminderDiscoveryError)?.errorDescription ?? "本次模型分析未完成，已有提醒和已完成进度已保留。")
            let before = state
            state.reminderDiscoveryCheckpoint.lastAttemptAt = .now
            state.reminderDiscoveryCheckpoint.failureReason = safeReason
            do { try persist() } catch { state = before }
            throw error
        }
    }

    private func validateReminderModelInput(_ ids: Set<UUID>, versions: [String: String], configuration: LLMConfiguration,
                                            privacy: PrivacySettings, automatic: Bool) throws {
        guard state.privacy == privacy, state.privacy.cloudUseEnabled, state.llmConfiguration == configuration,
              !automatic || state.reminderLearningProfile.automaticDiscovery == true else { throw ReminderDiscoveryError.changed }
        let current = state.correctedForAnalysis().captures.filter { ids.contains($0.id) }
        guard current.count == ids.count, current.allSatisfy({
            ModelReminderDiscovery.eligible($0, in: state) && versions[$0.id.uuidString] == MemoryKnowledgeEngine.version(of: $0)
        }) else { throw ReminderDiscoveryError.changed }
    }
}
