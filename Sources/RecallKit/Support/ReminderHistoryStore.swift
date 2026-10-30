import Foundation

public enum ReminderHistoryError: LocalizedError {
    case unavailableSource
    public var errorDescription: String? { "来源记录已不存在，无法恢复为待确认。可以删除这条历史记录。" }
}

public extension FileMemoryStore {
    /// Restore only existing terminal records. This never schedules or authorizes notifications.
    @discardableResult
    func restoreReminderHistory(ids: Set<UUID>, now: Date = .now) throws -> Int {
        let previous = state
        var restored = 0
        do {
            for index in state.reminders.indices where ids.contains(state.reminders[index].id) && state.reminders[index].status.isHistory {
                let old = state.reminders[index]
                if old.origin == .discovered {
                    let live = Set(state.captures.map(\.id))
                    guard !old.sourceCaptureIDs.isEmpty, Set(old.sourceCaptureIDs).isSubset(of: live) else { throw ReminderHistoryError.unavailableSource }
                }
                state.reminders[index].status = .proposed
                state.reminders[index].closedAt = nil; state.reminders[index].completedAt = nil
                state.reminders[index].scheduledAt = nil; state.reminders[index].dismissedUntil = nil
                state.reminders[index].snoozeCount = 0; state.reminders[index].updatedAt = now
                if (old.dueAt ?? .distantPast) <= now { state.reminders[index].dueAt = nil }
                let mark = ReminderHistorySuppression(reminder: old)
                state.reminderLearningProfile.clearedHistory?.removeAll { $0.fingerprint == mark.fingerprint && $0.dueAt == mark.dueAt }
                if old.status == .dismissed {
                    let key = old.semanticKey.isEmpty ? String(old.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).filter { $0.isLetter || $0.isNumber }) : old.semanticKey
                    if var stats = state.reminderLearningProfile.semanticFeedback[key] {
                        stats.dismissed = max(0, stats.dismissed - 1); stats.updatedAt = now
                        state.reminderLearningProfile.semanticFeedback[key] = stats
                    }
                }
                for i in state.dailySummaries.indices {
                    for j in state.dailySummaries[i].todos.indices where state.dailySummaries[i].todos[j].id == old.id {
                        state.dailySummaries[i].todos[j].status = .pending
                    }
                }
                restored += 1
            }
            if restored > 0 { try persist() }
            return restored
        } catch { state = previous; throw error }
    }

    /// Delete history, not original memories. A bounded, expiring fingerprint keeps prior vetoes effective.
    @discardableResult
    func removeReminderHistory(ids: Set<UUID>, onlyDismissed: Bool = false, now: Date = .now) throws -> Int {
        let removed = state.reminders.filter { ids.contains($0.id) && $0.status.isHistory && (!onlyDismissed || $0.status == .dismissed) }
        guard !removed.isEmpty else { return 0 }
        let previous = state
        do {
            state.reminderLearningProfile.retainHistorySuppression(removed, now: now)
            let actual = Set(removed.map(\.id))
            state.reminders.removeAll { actual.contains($0.id) }
            try persist()
            return removed.count
        } catch { state = previous; throw error }
    }

    func setReminderApplication(_ source: ReminderSourceChoice, disabled: Bool) throws {
        guard source.isApplication else { return }
        let previous = state
        do {
            var applications = state.reminderLearningProfile.disabledReminderApplications
            if disabled { applications[source.id] = source.title } else { applications.removeValue(forKey: source.id) }
            state.reminderLearningProfile.excludedApplications = applications
            if !disabled {
                // A re-enabled app must be eligible for the next incremental pass as well.
                for capture in state.captures where ReminderSourceChoice(capture: capture)?.id == source.id || source.id == ReminderSourceChoice.nameKey(capture.sourceAppName ?? "") {
                    state.reminderDiscoveryCheckpoint.processedCaptureHashes.removeValue(forKey: capture.id.uuidString)
                }
            }
            try persist()
        } catch { state = previous; throw error }
    }

    /// Merge inside the actor, so a scan cannot undo history actions taken while it was running.
    @discardableResult
    func applyReminderDiscovery(candidates: [ReminderCandidate], checkpoint: ReminderDiscoveryCheckpoint,
                                revalidatedSourceIDs: Set<UUID>, startedAt: Date, now: Date = .now) throws -> Int {
        let previous = state
        do {
            let sourceMap = Dictionary(state.correctedForAnalysis().captures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let profile = state.reminderLearningProfile
            let extractor = ReminderExtractor()
            let protected = state.reminders.filter { $0.updatedAt > startedAt }
            let protectedIDs = Set(protected.map(\.id))
            let proposals = candidates.filter { candidate in
                guard candidate.status == .proposed, candidate.origin == .discovered, !candidate.sourceCaptureIDs.isEmpty,
                      !profile.suppressesHistory(candidate, now: now),
                      !state.reminders.contains(where: { extractor.blocks(candidate: candidate, existing: $0, now: now) && $0.status != .proposed }),
                      !protected.contains(where: { $0.id == candidate.id || extractor.blocks(candidate: candidate, existing: $0, now: now) }) else { return false }
                return candidate.sourceCaptureIDs.allSatisfy { id in
                    guard let capture = sourceMap[id], profile.permitsReminderDiscovery(from: capture),
                          !state.privacy.excludedBundleIdentifiers.contains(capture.sourceBundleIdentifier ?? "") else { return false }
                    return checkpoint.processedCaptureHashes[id.uuidString] == MemoryKnowledgeEngine.version(of: capture)
                }
            }
            let known = Set(state.reminders.map(\.id))
            let current = state.reminders.filter { !protectedIDs.contains($0.id) }
            let validRevalidated = Set(revalidatedSourceIDs.filter { id in
                sourceMap[id].map { profile.permitsReminderDiscovery(from: $0)
                    && checkpoint.processedCaptureHashes[id.uuidString] == MemoryKnowledgeEngine.version(of: $0)
                    && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") } ?? false
            })
            var merged = extractor.merging(proposals, into: current, now: now, revalidatedCaptureIDs: validRevalidated) + protected
            merged = merged.filter { reminder in
                switch reminder.status {
                case .dismissed: return now.timeIntervalSince(reminder.dismissedUntil ?? reminder.closedAt ?? reminder.updatedAt) < 90 * 86_400
                case .completed, .cancelled: return now.timeIntervalSince(reminder.closedAt ?? reminder.completedAt ?? reminder.updatedAt) < 180 * 86_400
                default: return true
                }
            }.sorted {
                if $0.status.isHistory != $1.status.isHistory { return !$0.status.isHistory }
                return $0.updatedAt > $1.updatedAt
            }
            let retained = Array(merged.prefix(1_000))
            state.reminders = retained
            var next = checkpoint
            next.processedCaptureHashes = next.processedCaptureHashes.filter { id, _ in
                guard let uuid = UUID(uuidString: id), let capture = sourceMap[uuid] else { return false }
                return profile.permitsReminderDiscovery(from: capture)
            }
            state.reminderDiscoveryCheckpoint = next
            let addedCount = retained.filter { !known.contains($0.id) && $0.status == .proposed }.count
            state.reminderDiscoveryCheckpoint.discoveredCount = addedCount
            state.reminderDiscoveryCheckpoint.eligibleRecordCount = next.processedCaptureHashes.count
            state.reminderLearningProfile.clearedHistory?.removeAll { $0.expiresAt <= now }
            try persist()
            return addedCount
        } catch { state = previous; throw error }
    }
}
