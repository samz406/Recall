import Foundation

// Pure derivation on a value snapshot; no disk access, actor waits or model calls.
extension RecallState {
    mutating func reconcileForPersistence(force: Bool = false, now: Date = .now, allowNew: Bool = false) throws {
        reconcileDailyReviewCheckpoints()
        let liveIDs = Set(self.captures.map(\.id))
        let excludedIDs = Set(self.captures.filter { self.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }.map(\.id))
        let invalidIDs = Set(self.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let feedbackIDs = Set(self.summaryFeedback.map(\.id))
        var droppedIDs = Set(self.summaryFeedback.filter {
            !Set($0.sourceVersions.keys).isSubset(of: liveIDs) || !Set($0.sourceVersions.keys).isDisjoint(with: excludedIDs.union(invalidIDs))
                || !Set($0.dependencyFeedbackIDs ?? []).isSubset(of: feedbackIDs)
        }.map(\.id))
        for _ in self.summaryFeedback.indices {
            let more = Set(self.summaryFeedback.filter { !Set($0.dependencyFeedbackIDs ?? []).isDisjoint(with: droppedIDs) }.map(\.id))
            if more.isSubset(of: droppedIDs) { break }; droppedIDs.formUnion(more)
        }
        let droppedFeedback = self.summaryFeedback.filter { droppedIDs.contains($0.id) }
        if !droppedFeedback.isEmpty {
            let touched = Set(droppedFeedback.flatMap { $0.resolution?.corrections.map(\.sourceID) ?? [] })
            self.summaryFeedback.removeAll { entry in droppedFeedback.contains { $0.id == entry.id } }
            invalidateMemoryOutputs(sourceIDs: touched)
        }
        try Task.checkCancellation()
        reconcileCaptureUnderstanding()
        self.topicGroups.removeAll { group in group.sourceIDs.map { Set($0).isDisjoint(with: liveIDs) } ?? false }
        let knowledge = allowNew ? MemoryKnowledgeEngine().reconcile(self, force: force, now: now) : nil
        try Task.checkCancellation()
        invalidateWeeklyReports(knowledge: knowledge)
        let topicState = self
        self.topicReviews.removeAll { !$0.sourcesUnchanged(in: topicState) }
        try Task.checkCancellation()
        applyReconciledKnowledge(knowledge ?? MemoryKnowledgeEngine().reconcile(self, force: force, now: now, allowNew: allowNew))
        try Task.checkCancellation()
        self.memoryKnowledge.dependencies = MemoryKnowledgeEngine().dependencies(in: self, claims: self.memoryKnowledge.claims)
    }

    mutating func invalidateWeeklyReports(knowledge supplied: MemoryKnowledge? = nil) {
        // Daily-derived reports use their own exact source versions, not a global graph rebuild.
        let knowledge = supplied ?? (self.weeklyReports.contains { $0.isReadable && $0.dailySynthesisVersion == nil }
            ? MemoryKnowledgeEngine().reconcile(self) : nil)
        for i in self.weeklyReports.indices where self.weeklyReports[i].isReadable {
            if !WeeklyReviewEngine.sourcesUnchanged(self.weeklyReports[i], in: self, knowledge: knowledge) { self.weeklyReports[i].invalidate() }
            else {
                let ids = self.weeklyReports[i].sourceIDs
                self.weeklyReports[i].sourceVersions = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                    WeeklyReviewEngine.sourceVersion(id: id, state: self).map { (id, $0) }
                })
            }
        }
        for i in self.recentlyDeletedMemories.indices {
            guard var reports = self.recentlyDeletedMemories[i].weeklyReports else { continue }
            // A source in this same deletion transaction can be restored together with its report.
            var restorationState = self
            let existing = Set(self.captures.map(\.id))
            restorationState.captures += self.recentlyDeletedMemories[i].captures.filter { !existing.contains($0.id) }
            restorationState.matterCorrections += self.recentlyDeletedMemories[i].matterCorrections ?? []
            let restorationKnowledge = reports.contains { $0.isReadable } ? MemoryKnowledgeEngine().reconcile(restorationState) : nil
            for j in reports.indices where reports[j].isReadable {
                if !WeeklyReviewEngine.sourcesUnchanged(reports[j], in: restorationState, knowledge: restorationKnowledge) { reports[j].invalidate() }
            }
            self.recentlyDeletedMemories[i].weeklyReports = reports
        }
    }

    mutating func projectDayFromMatters(_ day: Date) {
        let calendar = Calendar.current
        let files = MatterMemoryEngine().sourceFiles(in: self)
        let sources = Dictionary(uniqueKeysWithValues: self.captures.map { ($0.id, $0) })
        let episodes: [WorkEpisode] = files.flatMap { file in
            file.events.filter { calendar.isDate($0.date, inSameDayAs: day) }.map { event in
                WorkEpisode(id: event.id, day: day, startedAt: event.date, endedAt: event.date,
                    projectKey: file.id, projectName: file.title, title: file.title, intent: file.title,
                    action: event.detail, outcome: event.resultStatus == .completed || event.status == .completed ? event.detail : nil,
                    nextAction: event.nextAction, status: event.status, importance: event.status == .blocked ? 0.9 : 0.8,
                    confidence: 0.8, sourceApps: event.evidenceIDs.compactMap { sources[$0]?.sourceAppName }.memoryUnique(), evidenceIDs: event.evidenceIDs)
            }
        }
        self.episodes.removeAll { calendar.isDate($0.day, inSameDayAs: day) }
        self.episodes.append(contentsOf: episodes)
        self.episodes.sort { $0.startedAt > $1.startedAt }
        for file in files where file.events.contains(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
            let project = ProjectState(projectKey: file.id, displayName: file.title, currentState: file.latest.detail,
                nextAction: file.latest.nextAction, blockers: file.latest.status == .blocked ? [file.latest.detail] : [],
                evidenceIDs: file.evidenceIDs, confidence: 0.8, lastActiveAt: file.latest.date)
            if let index = self.projects.firstIndex(where: { $0.projectKey == project.projectKey }) {
                self.projects[index] = project
            } else {
                self.projects.append(project)
            }
        }
    }

    mutating func reconcileDailyReviewCheckpoints(now: Date = .now) {
        let liveSummaries = Set(self.dailySummaries.map(\.id))
        self.pendingDailyReviewMaintenance.removeAll { !liveSummaries.contains($0) }
        self.pendingPersonaRefresh.removeAll { !liveSummaries.contains($0) }
        guard self.privacy.cloudUseEnabled else { self.dailyReviewCheckpoints = []; return }
        guard !self.dailyReviewCheckpoints.isEmpty else { return }
        let configuration = DailyReviewInput.configurationVersion(self.llmConfiguration)
        let revision = SummaryFeedbackLearning.revision(in: self)
        let tracked = Set(self.dailyReviewCheckpoints.flatMap { $0.sourceVersions.keys })
        let excluded = Set(self.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let versions = Dictionary(uniqueKeysWithValues: self.captures.filter {
            tracked.contains($0.id) && !excluded.contains($0.id) && !self.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "")
        }.map { ($0.id, CaptureUnderstandingEngine.sourceVersion($0, in: self)) })
        self.dailyReviewCheckpoints.removeAll { checkpoint in
            checkpoint.configurationVersion != configuration || checkpoint.feedbackRevision != revision
                || now.timeIntervalSince(checkpoint.createdAt) > 7 * 86_400
                || !checkpoint.sourceVersions.allSatisfy { versions[$0.key] == $0.value }
        }
    }

    mutating func reconcileCaptureUnderstanding() {
        let live = Set(self.captures.filter { CaptureUnderstandingEngine.eligible($0, in: self) }.map(\.id))
        let referenced = Set(self.understandingJobs.flatMap { $0.sourceVersions.keys })
            .union(self.captures.compactMap(\.understanding).flatMap { $0.sourceVersions.keys })
        let signatures = Dictionary(uniqueKeysWithValues: self.captures.filter { live.contains($0.id) && referenced.contains($0.id) }
            .map { ($0.id, CaptureUnderstandingEngine.sourceVersion($0, in: self)) })
        var invalid: Set<UUID> = []
        for i in self.captures.indices {
            if let result = self.captures[i].understanding, result.processorVersion != CaptureUnderstandingEngine.version || result.sourceVersions.isEmpty || !result.sourceVersions.allSatisfy({ signatures[$0.key] == $0.value }) {
                invalid.insert(self.captures[i].id); self.captures[i].understanding = nil
            }
        }
        self.understandingJobs.removeAll { !live.contains($0.captureID) }
        for i in self.understandingJobs.indices {
            let job = self.understandingJobs[i]
            if invalid.contains(job.captureID) || (!job.sourceVersions.isEmpty && !job.sourceVersions.allSatisfy({ signatures[$0.key] == $0.value })) {
                self.understandingJobs[i] = CaptureUnderstandingJob(captureID: job.captureID)
            }
        }
        if !invalid.isEmpty {
            invalidateMemoryOutputs(sourceIDs: invalid)
            self.reminderDiscoveryCheckpoint = ReminderDiscoveryCheckpoint()
            self.reminders.removeAll { $0.origin == .discovered && $0.status == .proposed && !Set($0.sourceCaptureIDs).isDisjoint(with: invalid) }
        }
    }

    mutating func migrateLegacyWeeklyVersions() {
        let snapshot = self
        for i in snapshot.weeklyReports.indices where snapshot.weeklyReports[i].isReadable
            && snapshot.weeklyReports[i].sourceVersions.values.contains(where: { !$0.hasPrefix("memory2:") }) {
            let report = snapshot.weeklyReports[i]
            if WeeklyReviewEngine.sourcesUnchanged(report, in: snapshot) {
                self.weeklyReports[i].sourceVersions = Dictionary(uniqueKeysWithValues: report.sourceIDs.compactMap { id in
                    WeeklyReviewEngine.sourceVersion(id: id, state: snapshot).map { (id, $0) }
                })
            }
        }
    }

}
