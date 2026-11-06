import Foundation
import Combine
import RecallKit

struct GlobalSearchTopic: Identifiable, Equatable {
    let id: String
    let title: String
    let sourceIDs: Set<UUID>
}

/// App-owned lazy search cache, shared by successive sheet presentations.
@MainActor
final class GlobalSearchWorkspace: ObservableObject {
    private struct Input: Equatable {
        var captures: [CaptureRecord]
        var daily: [DailySummary]
        var weekly: [WeeklyReport]
        var reminders: [ReminderCandidate]
        var claims: [MemoryClaim]
        var corrections: [MatterCorrection]
        var feedback: [SummaryFeedback]
        var excluded: Set<String>
        var matters: [MatterFile]
        var locale: String
        var timeZone: String
        init(_ state: RecallState, matters: [MatterFile]) {
            captures = state.captures; daily = state.dailySummaries; weekly = state.weeklyReports
            reminders = state.reminders; claims = state.memoryKnowledge.claims; corrections = state.matterCorrections
            feedback = state.summaryFeedback; excluded = state.privacy.excludedBundleIdentifiers; self.matters = matters
            locale = Locale.current.identifier + RecallLocalization.locale.identifier
            timeZone = TimeZone.current.identifier
        }
    }
    private struct Cached {
        let query: GlobalMemorySearchQuery
        let hits: [MemorySearchHit]
        let validUntil: Date?
    }
    @Published private(set) var hits: [MemorySearchHit] = []
    @Published private(set) var sources: [String] = []
    @Published private(set) var topics: [GlobalSearchTopic] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    private(set) var indexBuildCount = 0
    private(set) var resultBuildCount = 0
    private(set) var lastBuildMilliseconds = 0
    private var input: Input?
    private var state = RecallState()
    private var matters: [MatterFile] = []
    private var index: GlobalMemorySearch?
    private var query = GlobalMemorySearchQuery()
    private var cache: [Cached] = []
    private var active = false
    private var revision = UUID()
    private var requestID = UUID()
    private var buildTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    func update(_ state: RecallState, matters: [MatterFile]) {
        let next = Input(state, matters: matters)
        guard next != input else { return }
        input = next; self.state = state; self.matters = matters
        revision = UUID(); requestID = UUID()
        buildTask?.cancel(); resultTask?.cancel(); expiryTask?.cancel()
        buildTask = nil; index = nil; cache.removeAll()
        // Withdraw old results synchronously on deletion, correction or privacy changes.
        hits = []; isLoading = false; message = nil
        sources = Array(Set(state.captures.filter {
            !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "")
                && $0.isMemoryEvidenceArchive != true && $0.eventTemplate != .dailyReview && $0.memoryDirective == nil
        }.compactMap(\.sourceAppName))).sorted()
        let invalid = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let allowed = Set(state.captures.filter { !state.privacy.excludedBundleIdentifiers.contains($0.sourceBundleIdentifier ?? "") }.map(\.id)).subtracting(invalid)
        topics = matters.compactMap { file in
            let ids = Set(file.events.filter { !$0.evidenceIDs.isEmpty && Set($0.evidenceIDs).isSubset(of: allowed) }.flatMap(\.evidenceIDs))
            return ids.isEmpty ? nil : GlobalSearchTopic(id: file.id, title: file.title, sourceIDs: ids)
        }
        if active { setQuery(query, debounce: false) }
    }
    func activate(_ query: GlobalMemorySearchQuery = GlobalMemorySearchQuery()) {
        active = true; setQuery(query, debounce: false)
    }
    func deactivate() {
        active = false; requestID = UUID()
        resultTask?.cancel(); buildTask?.cancel(); expiryTask?.cancel()
        resultTask = nil; buildTask = nil; isLoading = false
    }
    func setQuery(_ next: GlobalMemorySearchQuery, debounce: Bool = true) {
        let changedText = next.text != query.text
        query = next; requestID = UUID()
        let request = requestID, revision = revision
        resultTask?.cancel(); expiryTask?.cancel()
        hits = []; message = nil
        guard active, next.hasCriteria else { isLoading = false; return }
        isLoading = true
        guard let index else { prepareIndex(); return }
        if let saved = cache.first(where: { $0.query == next && ($0.validUntil.map { $0 > Date.now } ?? true) }) {
            hits = saved.hits; isLoading = false; scheduleExpiry(saved.validUntil); return
        }
        resultTask = Task { [weak self] in
            do {
                if debounce && changedText { try await Task.sleep(for: .milliseconds(180)) }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) { try index.result(for: next) }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.active, self.requestID == request, self.revision == revision else { return }
                let expiry = index.nextExpiry()
                self.cache.insert(Cached(query: next, hits: result, validUntil: expiry), at: 0)
                self.cache = Array(self.cache.prefix(6))
                self.resultBuildCount += 1; self.hits = result; self.isLoading = false
                self.scheduleExpiry(expiry)
            } catch {
                guard let self, !Task.isCancelled, self.requestID == request else { return }
                self.isLoading = false
                self.message = RecallLocalization.both("搜索未能完成，请重试。", "Search could not finish. Try again.")
            }
        }
    }
    private func prepareIndex() {
        guard buildTask == nil else { return }
        let snapshot = state, files = matters, revision = revision
        buildTask = Task { [weak self] in
            let started = Date.now
            let worker = Task.detached(priority: .userInitiated) {
                let result = GlobalMemorySearch(state: snapshot, matters: files)
                try Task.checkCancellation()
                return result
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.active, self.revision == revision else { return }
                self.index = result; self.buildTask = nil; self.indexBuildCount += 1
                self.lastBuildMilliseconds = Int(Date.now.timeIntervalSince(started) * 1000)
                self.setQuery(self.query, debounce: false)
            } catch {
                guard let self, !Task.isCancelled, self.revision == revision else { return }
                self.buildTask = nil; self.isLoading = false
                self.message = RecallLocalization.both("搜索未能完成，请重试。", "Search could not finish. Try again.")
            }
        }
    }
    private func scheduleExpiry(_ date: Date?) {
        expiryTask?.cancel()
        guard active, let date else { return }
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0.01, date.timeIntervalSinceNow)))
                guard let self, !Task.isCancelled, self.active else { return }
                self.cache.removeAll(); self.setQuery(self.query, debounce: false)
            } catch { }
        }
    }
}

