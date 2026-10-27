import Foundation

extension FileMemoryStore {
    func forgetSummaryFeedback(reportID: UUID) {
        let removed = state.summaryFeedback.filter { $0.target.reportID == reportID }
        state.summaryFeedback.removeAll { $0.target.reportID == reportID }
        let touched = Set(removed.flatMap { $0.resolution?.corrections.map(\.sourceID) ?? [] })
        if !touched.isEmpty { invalidateMemoryOutputs(sourceIDs: touched) }
    }
    @discardableResult
    public func submitSummaryFeedback(target: SummaryFeedbackTarget, text: String, now: Date = .now) throws -> SummaryFeedback {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...1_200).contains(text.count), !target.items.isEmpty, target.items.count <= 20 else { throw SummaryFeedbackError.invalid }
        guard SummaryFeedbackLearning.targetIsCurrent(target, in: state) else { throw SummaryFeedbackError.changed }
        let ids = Set(target.items.flatMap(\.sourceIDs))
        let sources = state.captures.filter { ids.contains($0.id) }
        guard sources.count == ids.count, !sources.contains(where: { state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }) else { throw SummaryFeedbackError.changed }
        // Double clicks and retrying a submission don't create two jobs/rules.
        if let existing = state.summaryFeedback.last(where: { $0.target == target && $0.text == text && $0.state != .withdrawn }) { return existing }
        let before = state
        var entry = SummaryFeedback(target: target, text: text,
            sourceVersions: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, SummaryFeedbackLearning.rawVersion($0)) }))
        entry.createdAt = now; entry.updatedAt = now
        if target.editedText != nil {
            entry.state = .needsDetail; entry.message = "这份回顾有手工编辑的正文，已保留反馈。请在编辑中修改正文，或对自动整理的具体条目反馈。"
        }
        state.summaryFeedback.append(entry)
        do { try persist() } catch { state = before; throw error }
        return entry
    }
    public func recoverSummaryFeedbackJobs() throws {
        let before = state
        for i in state.summaryFeedback.indices where state.summaryFeedback[i].state == .processing {
            state.summaryFeedback[i].state = .queued; state.summaryFeedback[i].lease = nil
            state.summaryFeedback[i].message = "正在恢复上次尚未完成的核对。"
        }
        do { try persist() } catch { state = before; throw error }
    }
    public func claimSummaryFeedback(now: Date = .now, modelAvailable: Bool) throws -> SummaryFeedback? {
        guard state.summaryFeedbackSettings.processingEnabled else { return nil }
        let before = state
        for i in state.summaryFeedback.indices where state.summaryFeedback[i].state == .processing && now.timeIntervalSince(state.summaryFeedback[i].updatedAt) > 300 {
            state.summaryFeedback[i].state = .retrying; state.summaryFeedback[i].lease = nil; state.summaryFeedback[i].retryAfter = now
        }
        guard let i = state.summaryFeedback.firstIndex(where: {
            [.queued, .waiting, .retrying].contains($0.state) && ($0.retryAfter == nil || $0.retryAfter! <= now)
        }) else { return nil }
        guard modelAvailable, state.privacy.cloudUseEnabled else {
            if state.summaryFeedback[i].state != .waiting {
                state.summaryFeedback[i].state = .waiting
                state.summaryFeedback[i].message = "反馈已保存在本机；连接模型并允许文本使用后继续核对。"
                do { try persist() } catch { state = before; throw error }
            }
            return nil
        }
        guard SummaryFeedbackLearning.targetIsCurrent(state.summaryFeedback[i].target, in: state) else {
            state.summaryFeedback[i].state = .needsDetail
            state.summaryFeedback[i].message = SummaryFeedbackError.changed.localizedDescription
            do { try persist() } catch { state = before; throw error }
            return nil
        }
        state.summaryFeedback[i].state = .processing; state.summaryFeedback[i].lease = UUID()
        state.summaryFeedback[i].attempts += 1; state.summaryFeedback[i].updatedAt = now
        state.summaryFeedback[i].processorVersion = 1
        state.summaryFeedback[i].processingRevision = SummaryFeedbackLearning.revision(in: state)
        state.summaryFeedback[i].message = "正在核对反馈与相关记录。"
        do { try persist() } catch { state = before; throw error }
        return state.summaryFeedback[i]
    }
    public func validateSummaryFeedbackJob(_ job: SummaryFeedback, configuration: LLMConfiguration, privacy: PrivacySettings, extraSources: [UUID: String] = [:]) throws {
        guard state.summaryFeedbackSettings.processingEnabled, state.privacy == privacy, state.privacy.cloudUseEnabled,
              state.llmConfiguration == configuration,
              let current = state.summaryFeedback.first(where: { $0.id == job.id }), current.state == .processing, current.lease == job.lease,
              current.processingRevision == SummaryFeedbackLearning.revision(in: state),
              SummaryFeedbackLearning.targetIsCurrent(job.target, in: state) else { throw SummaryFeedbackError.changed }
        let sources = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0) })
        guard job.sourceVersions.merging(extraSources, uniquingKeysWith: { _, new in new }).allSatisfy({ id, version in sources[id].map { SummaryFeedbackLearning.rawVersion($0) == version && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") } ?? false }) else { throw SummaryFeedbackError.changed }
    }
    public func finishSummaryFeedback(_ job: SummaryFeedback, plan: SummaryFeedbackPlan, configuration: LLMConfiguration,
                                      privacy: PrivacySettings, now: Date = .now) throws {
        try Task.checkCancellation()
        try validateSummaryFeedbackJob(job, configuration: configuration, privacy: privacy)
        guard plan.learningRevision == SummaryFeedbackLearning.revision(in: state), let index = state.summaryFeedback.firstIndex(where: { $0.id == job.id }) else { throw SummaryFeedbackError.changed }
        var sources = Dictionary(uniqueKeysWithValues: state.captures.map { ($0.id, $0) })
        guard plan.sourceVersions.allSatisfy({ id, version in sources[id].map { SummaryFeedbackLearning.rawVersion($0) == version && !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") } ?? false }) else { throw SummaryFeedbackError.changed }
        let before = state
        do {
            var entry = state.summaryFeedback[index]
            entry.resolution = plan.resolution; entry.updatedAt = now; entry.lease = nil
            entry.sourceVersions.merge(plan.sourceVersions) { _, new in new }
            if plan.resolution.diagnosis == .unclear || (plan.resolution.changes.isEmpty && plan.resolution.corrections.isEmpty && plan.resolution.rules.isEmpty && plan.resolution.supplement == nil) {
                entry.state = .needsDetail; entry.message = plan.resolution.message.isEmpty ? "请补充哪一条不对，以及实际发生了什么。" : plan.resolution.message
                state.summaryFeedback[index] = entry; try persist(); return
            }
            if let supplement = plan.resolution.supplement {
                guard let day = SummaryFeedbackLearning.supplementDate(supplement, feedback: job) else { throw SummaryFeedbackError.invalid }
                let note = ManualMatterNote(title: supplement.title, detail: supplement.detail, status: supplement.status,
                    eventAt: day, reviewCategory: job.target.templateKind?.requiresWorkScope == true ? .work : nil)
                var capture = try note.capture(recordedAt: job.createdAt)
                capture.id = job.id; capture.sourceAppName = "用户反馈补记"
                state.captures.insert(capture, at: 0); sources[capture.id] = capture
                entry.supplementCaptureID = capture.id
                entry.sourceVersions[capture.id] = SummaryFeedbackLearning.rawVersion(capture)
            }
            for correction in plan.resolution.corrections {
                guard let source = sources[correction.sourceID], SummaryFeedbackLearning.adjusted(source, in: before).ocrText.components(separatedBy: correction.originalQuote).count == 2 else { throw SummaryFeedbackError.changed }
            }
            let correctedIDs = Set(plan.resolution.corrections.map(\.sourceID))
            entry.dependencyFeedbackIDs = before.summaryFeedback.filter { old in
                old.state == .applied && !(Set(old.resolution?.corrections.map(\.sourceID) ?? [])).isDisjoint(with: correctedIDs)
            }.map(\.id)
            entry.state = .applied
            entry.message = plan.resolution.message.isEmpty ? "已按反馈调整。" : plan.resolution.message
            state.summaryFeedback[index] = entry
            let changedSources = Set(plan.resolution.corrections.map(\.sourceID))
            // Save the old report before retracting dependent materializations, then publish the patch atomically.
            if job.target.kind == .daily { entry.dailyBefore = state.dailySummaries.first { $0.id == job.target.reportID } }
            else { entry.weeklyBefore = state.weeklyReports.first { $0.id == job.target.reportID } }
            if !changedSources.isEmpty {
                invalidateMemoryOutputs(sourceIDs: changedSources)
                reconcileCaptureUnderstanding()
                applyKnowledge(MemoryKnowledgeEngine().reconcile(state, force: true))
                state.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
                // No automatic notification/state changes. Only weak discovered proposals are withdrawn.
                state.reminders.removeAll { $0.origin == .discovered && $0.status == .proposed && !Set($0.sourceCaptureIDs).isDisjoint(with: changedSources) }
            }
            if var summary = entry.dailyBefore {
                summary.versions = Array(([DailyReviewVersion(summary: summary)] + (summary.versions ?? [])).prefix(8))
                for change in plan.resolution.changes {
                    if let id = change.itemID, let i = summary.items.firstIndex(where: { $0.id.uuidString == id }) {
                        if change.remove { summary.items.remove(at: i); continue }
                        summary.items[i].title = change.title; summary.items[i].detail = change.detail
                        summary.items[i].section = DailySummarySection(rawValue: change.section) ?? .progress
                        summary.items[i].evidenceIDs = change.sourceIDs
                    } else if change.itemID == nil, !change.remove {
                        summary.items.append(DailySummaryItem(section: DailySummarySection(rawValue: change.section) ?? .progress,
                            title: change.title, detail: change.detail, evidenceIDs: change.sourceIDs))
                    } else { throw SummaryFeedbackError.changed }
                }
                summary.items = summary.modelCoverage == nil ? DailySummaryItemParser.sanitized(summary.items) : DailySummaryItemParser.modelValidated(summary.items)
                summary.modelOverview = nil
                summary.todos = summary.todos.compactMap { old in
                    guard let item = summary.items.first(where: { ($0.actionCandidateID == old.id || $0.title == old.title) && $0.section == .actions }) else { return nil }
                    var todo = old; todo.title = item.title; todo.detail = item.detail; return todo
                }
                summary.content = summary.modelCoverage == nil ? DailySummaryItemParser.markdown(from: summary.items) : DailySummaryItemParser.reviewedMarkdown(from: summary.items); summary.briefing = nil
                summary.sourceCaptureIDs = Array(Set(summary.sourceCaptureIDs + summary.items.flatMap(\.evidenceIDs)))
                state.dailySummaries.removeAll { $0.id == summary.id }; state.dailySummaries.insert(summary, at: 0)
                entry.resultRevision = SummaryFeedbackLearning.hash(summary)
            }
            if var report = entry.weeklyBefore {
                for change in plan.resolution.changes {
                    if let id = change.itemID, let i = report.items.firstIndex(where: { $0.id == id }) {
                        if change.remove {
                            report.digestTopicIDs = (report.digestTopicIDs ?? report.digestRows.map(\.id)).filter { $0 != id }
                            report.items[i].narrative = nil; continue
                        }
                        let excerptIDs = report.items[i].excerpts.filter { !Set($0.sourceIDs).isDisjoint(with: change.sourceIDs) }.map(\.id)
                        report.items[i].narrative = ReviewNarrative(title: change.title, summary: change.detail, evidenceIDs: excerptIDs)
                        report.items[i].section = ReviewSection(rawValue: change.section) ?? .progress
                    } else if change.itemID == nil, !change.remove {
                        let excerpts = change.sourceIDs.compactMap { id -> ReviewExcerpt? in
                            guard let source = sources[id] else { return nil }
                            return ReviewExcerpt(id: UUID(), date: source.createdAt, text: source.ocrText, status: .pending, sourceIDs: [id])
                        }
                        let id = "feedback:" + UUID().uuidString
                        report.items.append(ReviewItem(id: id, title: change.title, category: report.template.kind.requiresWorkScope ? .work : .unclassified,
                            section: ReviewSection(rawValue: change.section) ?? .notes, previous: nil, excerpts: excerpts,
                            featuredIDs: excerpts.map(\.id), nextAction: nil, nextActionSourceIDs: [],
                            narrative: ReviewNarrative(title: change.title, summary: change.detail, evidenceIDs: excerpts.map(\.id))))
                        report.digestTopicIDs = (report.digestTopicIDs ?? report.digestRows.map(\.id)) + [id]
                    } else { throw SummaryFeedbackError.changed }
                }
                let ids = report.sourceIDs.union(plan.resolution.changes.flatMap(\.sourceIDs))
                report.sourceVersions = Dictionary(uniqueKeysWithValues: ids.compactMap { id in WeeklyReviewEngine.sourceVersion(id: id, state: state).map { (id, $0) } })
                report.updatedAt = now; report.refinementPending = false; report.modelOverview = nil
                for change in plan.resolution.changes where !change.remove {
                    guard report.digestRows.contains(where: { $0.title == change.title && $0.summary == change.detail }) else { throw SummaryFeedbackError.invalid }
                }
                state.weeklyReports.removeAll { $0.id == report.id }; state.weeklyReports.insert(report, at: 0)
                entry.resultRevision = SummaryFeedbackLearning.hash(report)
            }
            if var backup = entry.weeklyBefore {
                // A week may contain thousands of ledger entries. Store only the changed rows and original order.
                entry.weeklyOriginalItemOrder = backup.items.map(\.id)
                let changed = Set(plan.resolution.changes.compactMap(\.itemID))
                backup.items.removeAll { !changed.contains($0.id) }
                entry.weeklyBefore = backup
            }
            state.summaryFeedback[index] = entry
            try persist()
        } catch { state = before; throw error }
    }
    public func failSummaryFeedback(_ job: SummaryFeedback, changed: Bool, now: Date = .now) throws {
        guard let i = state.summaryFeedback.firstIndex(where: { $0.id == job.id && $0.lease == job.lease && $0.state == .processing }) else { return }
        let before = state
        state.summaryFeedback[i].lease = nil; state.summaryFeedback[i].updatedAt = now
        if !state.summaryFeedbackSettings.processingEnabled || !state.privacy.cloudUseEnabled {
            state.summaryFeedback[i].state = state.privacy.cloudUseEnabled ? .queued : .waiting
            state.summaryFeedback[i].message = "处理已暂停；保留反馈，恢复设置后继续。"
        } else if changed {
            state.summaryFeedback[i].state = .needsDetail; state.summaryFeedback[i].message = SummaryFeedbackError.changed.localizedDescription
        } else if job.attempts < 3 {
            state.summaryFeedback[i].state = .retrying
            state.summaryFeedback[i].retryAfter = now.addingTimeInterval(job.attempts == 1 ? 60 : 300)
            state.summaryFeedback[i].message = "暂未完成核对，原内容保留，稍后会重试。"
        } else {
            state.summaryFeedback[i].state = .failed; state.summaryFeedback[i].message = "核对未通过或模型暂不可用。原内容已保留，可以稍后重试或补充反馈。"
        }
        do { try persist() } catch { state = before; throw error }
    }
    public func retrySummaryFeedback(_ id: UUID) throws {
        guard let i = state.summaryFeedback.firstIndex(where: { $0.id == id && [.failed, .waiting, .retrying].contains($0.state) }) else { return }
        let before = state
        state.summaryFeedback[i].state = .queued; state.summaryFeedback[i].attempts = 0; state.summaryFeedback[i].retryAfter = nil
        do { try persist() } catch { state = before; throw error }
    }
    public func withdrawSummaryFeedback(_ id: UUID) throws {
        let before = state
        withdrawSummaryFeedbackState(id)
        do { try persist() } catch { state = before; throw error }
    }
    private func withdrawSummaryFeedbackState(_ id: UUID) {
        guard let index = state.summaryFeedback.firstIndex(where: { $0.id == id && $0.state != .withdrawn }) else { return }
        let entry = state.summaryFeedback[index]
        let restoreDaily = state.dailySummaries.first { $0.id == entry.target.reportID }.map { SummaryFeedbackLearning.hash($0) == entry.resultRevision } ?? false
        let currentWeekly = state.weeklyReports.first { $0.id == entry.target.reportID }
        let restoreWeekly = currentWeekly.map { SummaryFeedbackLearning.hash($0) == entry.resultRevision } ?? false
        state.summaryFeedback[index].state = .withdrawn; state.summaryFeedback[index].lease = nil
        state.summaryFeedback[index].message = "已撤销这次反馈的调整及学习。"; state.summaryFeedback[index].updatedAt = .now
        var corrected = Set(entry.resolution?.corrections.map(\.sourceID) ?? [])
        var withdrawnIDs: Set<UUID> = [id]
        for _ in state.summaryFeedback.indices {
            let dependent = state.summaryFeedback.filter {
                $0.state == .applied && !(Set($0.dependencyFeedbackIDs ?? [])).isDisjoint(with: withdrawnIDs)
            }
            if dependent.isEmpty { break }
            for value in dependent {
                withdrawnIDs.insert(value.id)
                corrected.formUnion(value.resolution?.corrections.map(\.sourceID) ?? [])
                if let i = state.summaryFeedback.firstIndex(where: { $0.id == value.id }) {
                    state.summaryFeedback[i].state = .withdrawn
                    state.summaryFeedback[i].message = "依赖的更正已撤销，这次调整已停用。"
                }
            }
        }
        if let supplemental = entry.supplementCaptureID {
            corrected.insert(supplemental)
            state.captures.removeAll { $0.id == supplemental }
            state.summaryFeedback[index].sourceVersions.removeValue(forKey: supplemental)
        }
        if !corrected.isEmpty {
            invalidateMemoryOutputs(sourceIDs: corrected)
            applyKnowledge(MemoryKnowledgeEngine().reconcile(state, force: true))
        }
        let live = Set(state.captures.map(\.id))
        let originalsUnchanged = entry.sourceVersions.filter { $0.key != entry.supplementCaptureID }.allSatisfy { id, version in
            state.captures.first { $0.id == id }.map { SummaryFeedbackLearning.rawVersion($0) == version } ?? false
        }
        if restoreDaily, originalsUnchanged, let old = entry.dailyBefore, Set(old.sourceCaptureIDs).isSubset(of: live) {
            state.dailySummaries.removeAll { $0.id == old.id }; state.dailySummaries.insert(old, at: 0)
        }
        if restoreWeekly, originalsUnchanged, var old = entry.weeklyBefore, old.sourceIDs.isSubset(of: live) {
            if let order = entry.weeklyOriginalItemOrder, let currentWeekly {
                var byID = Dictionary(uniqueKeysWithValues: currentWeekly.items.map { ($0.id, $0) })
                for item in old.items { byID[item.id] = item }
                old.items = order.compactMap { byID[$0] }
            }
            old.sourceVersions = Dictionary(uniqueKeysWithValues: old.sourceIDs.compactMap { id in WeeklyReviewEngine.sourceVersion(id: id, state: state).map { (id, $0) } })
            state.weeklyReports.removeAll { $0.id == old.id }; state.weeklyReports.insert(old, at: 0)
        }
    }
    public func deleteSummaryFeedback(_ id: UUID) throws {
        let before = state
        do {
            withdrawSummaryFeedbackState(id)
            var removed: Set<UUID> = [id]
            for _ in state.summaryFeedback.indices {
                let descendants = Set(state.summaryFeedback.filter { !Set($0.dependencyFeedbackIDs ?? []).isDisjoint(with: removed) }.map(\.id))
                if descendants.isSubset(of: removed) { break }; removed.formUnion(descendants)
            }
            state.summaryFeedback.removeAll { removed.contains($0.id) }; try persist()
        } catch { state = before; throw error }
    }
    public func disableSummaryRule(feedbackID: UUID, ruleID: UUID) throws {
        guard let i = state.summaryFeedback.firstIndex(where: { $0.id == feedbackID }),
              state.summaryFeedback[i].resolution?.rules.contains(where: { $0.id == ruleID }) == true else { return }
        let before = state
        state.summaryFeedback[i].disabledRuleIDs.append(ruleID)
        do { try persist() } catch { state = before; throw error }
    }
    public func updateSummaryFeedbackSettings(_ settings: SummaryFeedbackSettings) throws {
        let before = state; state.summaryFeedbackSettings = settings
        do { try persist() } catch { state = before; throw error }
    }
}
