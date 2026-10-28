import Foundation

extension FileMemoryStore {
    public func correctCaptureText(_ captureID: UUID, text: String?) throws {
        guard let index = state.captures.firstIndex(where: { $0.id == captureID }) else { throw CaptureUnderstandingError.changed }
        if let text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 120_000 { throw CaptureUnderstandingError.invalid }
        let before = state
        state.captures[index].correctedText = text.map { PrivacyEngine().redact($0) }
        invalidateMemoryOutputs(sourceIDs: [captureID])
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
        state.reminders.removeAll { $0.origin == .discovered && $0.status == .proposed && $0.sourceCaptureIDs.contains(captureID) }
        do { try persist() } catch { state = before; throw error }
    }
    public func updateCaptureUnderstandingSettings(_ settings: CaptureUnderstandingSettings, now: Date = .now) throws {
        let before = state
        var next = settings
        if next.enabled && next.enabledSince == nil { next.enabledSince = now }
        state.understandingSettings = next
        if !next.enabled {
            for i in state.understandingJobs.indices where state.understandingJobs[i].state == .processing && state.understandingJobs[i].isReviewPreparation != true {
                state.understandingJobs[i].state = .queued; state.understandingJobs[i].lease = nil
            }
        }
        do { try persist() } catch { state = before; throw error }
    }

    /// Explicit backfill is bounded by date. No silent upload of the entire archive on enable.
    @discardableResult
    public func enqueueCaptureUnderstanding(since: Date? = nil, captureID: UUID? = nil, force: Bool = false, forReview: Bool = false, now: Date = .now) throws -> Int {
        guard forReview || state.understandingSettings.enabled else { throw CaptureUnderstandingError.unavailable }
        let before = state
        let eligible = state.captures.filter {
            CaptureUnderstandingEngine.eligible($0, in: state) && (captureID == nil || $0.id == captureID)
                && (captureID != nil || $0.createdAt >= (since ?? state.understandingSettings.enabledSince ?? now))
        }
        var count = 0
        let existingIDs = Set(state.understandingJobs.map(\.captureID))
        for source in eligible {
            if !force, source.understanding?.processorVersion == CaptureUnderstandingEngine.version || existingIDs.contains(source.id) { continue }
            if let old = state.understandingJobs.firstIndex(where: { $0.captureID == source.id }) {
                if !force { continue }
                state.understandingJobs.remove(at: old)
            }
            state.understandingJobs.append(CaptureUnderstandingJob(captureID: source.id, now: now)); count += 1
        }
        guard count > 0 else { return 0 }
        do { try persist() } catch { state = before; throw error }
        return count
    }

    public func recoverCaptureUnderstandingJobs() throws {
        let before = state
        for i in state.understandingJobs.indices where state.understandingJobs[i].state == .processing {
            state.understandingJobs[i].state = .queued; state.understandingJobs[i].lease = nil
        }
        do { try persist() } catch { state = before; throw error }
    }

    /// Retry the failed page without discarding previously accepted pages. Changed input
    /// or configuration will still reset the checkpoint when a new lease is claimed.
    @discardableResult
    public func retryCaptureUnderstanding(_ captureID: UUID, forReview: Bool = false) throws -> Int {
        guard forReview || state.understandingSettings.enabled else { throw CaptureUnderstandingError.unavailable }
        guard let index = state.understandingJobs.firstIndex(where: { $0.captureID == captureID }),
              [.failed, .retrying].contains(state.understandingJobs[index].state) else { return 0 }
        let before = state
        state.understandingJobs[index].state = .queued
        state.understandingJobs[index].attempts = 0
        state.understandingJobs[index].retryAt = nil
        state.understandingJobs[index].lease = nil
        do { try persist() } catch { state = before; throw error }
        return 1
    }

    public func claimCaptureUnderstanding(captureID: UUID? = nil, forReview: Bool = false, now: Date = .now) throws -> CaptureUnderstandingJob? {
        guard (forReview || state.understandingSettings.enabled), state.privacy.cloudUseEnabled,
              state.llmConfiguration.provider != .localOnly, !state.llmConfiguration.apiKey.isEmpty else { return nil }
        let before = state
        for i in state.understandingJobs.indices where state.understandingJobs[i].state == .processing && now.timeIntervalSince(state.understandingJobs[i].updatedAt) > 600 {
            state.understandingJobs[i].state = .queued; state.understandingJobs[i].lease = nil
        }
        // Older queued records first prevents starvation during an explicit backfill.
        guard let index = state.understandingJobs.indices.filter({
            [.queued, .retrying].contains(state.understandingJobs[$0].state)
                && (captureID == nil || state.understandingJobs[$0].captureID == captureID)
                && (state.understandingJobs[$0].retryAt ?? .distantPast) <= now
        }).min(by: { state.understandingJobs[$0].updatedAt < state.understandingJobs[$1].updatedAt }) else { return nil }
        let pages = CaptureUnderstandingEngine.pages(for: state.understandingJobs[index].captureID, in: state)
        guard let first = pages.first else {
            state.understandingJobs.remove(at: index)
            do { try persist() } catch { state = before; throw error }; return nil
        }
        let configEncoder = JSONEncoder(); configEncoder.outputFormatting = [.sortedKeys]
        let configData = (try? configEncoder.encode(state.llmConfiguration)) ?? Data()
        let configVersion = CaptureUnderstandingEngine.digest(configData.base64EncodedString())
        if state.understandingJobs[index].sourceVersions != first.sourceVersions || state.understandingJobs[index].configurationVersion != configVersion || state.understandingJobs[index].processorVersion != CaptureUnderstandingEngine.version {
            state.understandingJobs[index] = CaptureUnderstandingJob(captureID: state.understandingJobs[index].captureID, now: now)
        }
        state.understandingJobs[index].processorVersion = CaptureUnderstandingEngine.version
        state.understandingJobs[index].configurationVersion = configVersion
        state.understandingJobs[index].sourceVersions = first.sourceVersions
        state.understandingJobs[index].pageCount = pages.count
        state.understandingJobs[index].state = .processing
        state.understandingJobs[index].isReviewPreparation = forReview
        state.understandingJobs[index].lease = UUID()
        state.understandingJobs[index].attempts += 1
        state.understandingJobs[index].updatedAt = now
        do { try persist() } catch { state = before; throw error }
        return state.understandingJobs[index]
    }

    public func captureUnderstandingPage(_ job: CaptureUnderstandingJob) throws -> UnderstandingPage {
        let pages = CaptureUnderstandingEngine.pages(for: job.captureID, in: state)
        guard pages.indices.contains(job.nextPage), pages[job.nextPage].sourceVersions == job.sourceVersions else { throw CaptureUnderstandingError.changed }
        return pages[job.nextPage]
    }

    public func validateCaptureUnderstandingJob(_ job: CaptureUnderstandingJob, configuration: LLMConfiguration, privacy: PrivacySettings, forReview: Bool = false) throws {
        guard (forReview || state.understandingSettings.enabled), state.privacy.cloudUseEnabled, state.privacy == privacy,
              state.llmConfiguration == configuration,
              let current = state.understandingJobs.first(where: { $0.id == job.id }),
              current.state == .processing, current.lease == job.lease, current.nextPage == job.nextPage,
              job.processorVersion == CaptureUnderstandingEngine.version,
              !job.sourceVersions.isEmpty else { throw CaptureUnderstandingError.changed }
        let sources = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0) })
        guard job.sourceVersions.allSatisfy({ id, signature in
            sources[id].map { CaptureUnderstandingEngine.eligible($0, in: state) && CaptureUnderstandingEngine.sourceVersion($0, in: state) == signature } ?? false
        }) else { throw CaptureUnderstandingError.changed }
    }

    public func finishCaptureUnderstandingPage(_ job: CaptureUnderstandingJob, result: UnderstandingPageResult,
                                               configuration: LLMConfiguration, privacy: PrivacySettings, forReview: Bool = false, now: Date = .now) throws {
        try Task.checkCancellation()
        try validateCaptureUnderstandingJob(job, configuration: configuration, privacy: privacy, forReview: forReview)
        guard let index = state.understandingJobs.firstIndex(where: { $0.id == job.id }),
              let captureIndex = state.captures.firstIndex(where: { $0.id == job.captureID }) else { throw CaptureUnderstandingError.changed }
        let before = state
        var updated = state.understandingJobs[index]
        for fact in result.facts {
            if let i = updated.facts.firstIndex(where: { $0.id == fact.id }) {
                updated.facts[i].evidence = Array(Set(updated.facts[i].evidence + fact.evidence)).sorted { $0.blockID == $1.blockID ? $0.quote < $1.quote : $0.blockID < $1.blockID }
            } else { updated.facts.append(fact) }
        }
        updated.coveredBlocks += result.covered; updated.uncertainBlocks += result.uncertain
        updated.nextPage += 1; updated.attempts = 0; updated.lease = nil; updated.retryAt = nil; updated.updatedAt = now
        updated.lastFailureCode = nil; updated.lastFailureReason = nil; updated.isReviewPreparation = nil
        updated.state = updated.nextPage == updated.pageCount ? .completed : .queued
        if updated.state == .completed {
            state.captures[captureIndex].understanding = CaptureUnderstanding(processorVersion: CaptureUnderstandingEngine.version,
                sourceVersions: job.sourceVersions, createdAt: now, facts: updated.facts,
                coveredBlockCount: updated.coveredBlocks, uncertainBlockCount: updated.uncertainBlocks)
            updated.facts = [] // Completed jobs keep metadata, not a second copy of deleted evidence.
            state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
            state.reminders.removeAll { $0.origin == .discovered && $0.status == .proposed && $0.sourceCaptureIDs.contains(job.captureID) }
            // Rebuild derived claims. Existing user-reviewed reports remain until regeneration;
            // source edits/deletions use the stronger invalidation path below.
            state.memoryKnowledge = MemoryKnowledgeEngine().reconcile(state)
        }
        state.understandingJobs[index] = updated
        do { try persist(preservingReviewsFrom: before) } catch { state = before; throw error }
    }

    public func failCaptureUnderstanding(_ job: CaptureUnderstandingJob, changed: Bool, error: Error? = nil, now: Date = .now) throws {
        guard let i = state.understandingJobs.firstIndex(where: { $0.id == job.id && $0.lease == job.lease }) else { return }
        let before = state
        if changed {
            state.understandingJobs[i] = CaptureUnderstandingJob(captureID: job.captureID, now: now)
        } else {
            state.understandingJobs[i].lease = nil
            state.understandingJobs[i].state = job.attempts >= 3 ? .failed : .retrying
            state.understandingJobs[i].retryAt = now.addingTimeInterval(pow(2, Double(job.attempts)) * 30)
            state.understandingJobs[i].updatedAt = now
            state.understandingJobs[i].isReviewPreparation = nil
            if let error {
                state.understandingJobs[i].lastFailureCode = ReviewProcessingDiagnostics.code(for: error)
                state.understandingJobs[i].lastFailureReason = ReviewProcessingDiagnostics.reason(for: error)
            }
        }
        do { try persist() } catch { state = before; throw error }
    }

    public func removeCaptureUnderstanding(_ captureID: UUID) throws {
        let before = state
        if let i = state.captures.firstIndex(where: { $0.id == captureID }) { state.captures[i].understanding = nil }
        state.understandingJobs.removeAll { $0.captureID == captureID }
        var ignored = CaptureUnderstandingJob(captureID: captureID); ignored.state = .discarded
        state.understandingJobs.append(ignored)
        invalidateMemoryOutputs(sourceIDs: [captureID])
        state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
        state.reminders.removeAll { $0.origin == .discovered && $0.status == .proposed && $0.sourceCaptureIDs.contains(captureID) }
        do { try persist() } catch { state = before; throw error }
    }

    /// Called on every mutation, including feedback, source deletion, expiry and privacy changes.
    /// No model job can keep a quote alive after its source has gone away.
    func reconcileCaptureUnderstanding() {
        let live = Set(state.captures.filter { CaptureUnderstandingEngine.eligible($0, in: state) }.map(\.id))
        let referenced = Set(state.understandingJobs.flatMap { $0.sourceVersions.keys })
            .union(state.captures.compactMap(\.understanding).flatMap { $0.sourceVersions.keys })
        let signatures = Dictionary(uniqueKeysWithValues: state.captures.filter { live.contains($0.id) && referenced.contains($0.id) }
            .map { ($0.id, CaptureUnderstandingEngine.sourceVersion($0, in: state)) })
        var invalid: Set<UUID> = []
        for i in state.captures.indices {
            if let result = state.captures[i].understanding, result.processorVersion != CaptureUnderstandingEngine.version || result.sourceVersions.isEmpty || !result.sourceVersions.allSatisfy({ signatures[$0.key] == $0.value }) {
                invalid.insert(state.captures[i].id); state.captures[i].understanding = nil
            }
        }
        state.understandingJobs.removeAll { !live.contains($0.captureID) }
        for i in state.understandingJobs.indices {
            let job = state.understandingJobs[i]
            if invalid.contains(job.captureID) || (!job.sourceVersions.isEmpty && !job.sourceVersions.allSatisfy({ signatures[$0.key] == $0.value })) {
                state.understandingJobs[i] = CaptureUnderstandingJob(captureID: job.captureID)
            }
        }
        if !invalid.isEmpty {
            invalidateMemoryOutputs(sourceIDs: invalid)
            state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
            state.reminders.removeAll { $0.origin == .discovered && $0.status == .proposed && !Set($0.sourceCaptureIDs).isDisjoint(with: invalid) }
        }
    }
}
