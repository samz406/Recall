import Foundation
import Combine
import RecallKit

/// Owned by the app model so menu switches reuse the date index and last result.
@MainActor
final class TimelineWorkspace: ObservableObject {
    @Published var query = TimelineQuery() {
        didSet { if query != oldValue { prepareResult(debounce: query.searchText != oldValue.searchText) } }
    }
    @Published private(set) var days: [TimelineDayCount] = []
    @Published private(set) var sources: [String] = []
    @Published private(set) var result = TimelineQueryResult.empty
    @Published private(set) var isLoading = false
    @Published private(set) var sourceRevision = UUID()
    private(set) var maximumDayCount = 1
    private(set) var indexBuildCount = 0
    private(set) var resultBuildCount = 0
    private var index: TimelineIndex?
    private var records: [CaptureRecord] = []
    private var calendar: Calendar?
    private var buildTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var requestID = UUID()
    private var cache: [(TimelineQuery, TimelineQueryResult)] = []

    func update(captures: [CaptureRecord], calendar: Calendar = .current) {
        guard self.calendar != calendar || records != captures else { return }
        self.calendar = calendar; records = captures
        buildTask?.cancel(); resultTask?.cancel()
        let revision = UUID(); sourceRevision = revision
        requestID = UUID(); index = nil; cache.removeAll()
        // Never leave a deleted or corrected record visible while the new index builds.
        result = .empty; days = []; sources = []; isLoading = !captures.isEmpty
        buildTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try TimelineIndex(captures: captures, calendar: calendar) }
            do {
                let updated = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.sourceRevision == revision else { return }
                self.index = updated; self.indexBuildCount += 1
                self.maximumDayCount = updated.maximumDayCount
                self.days = updated.days; self.sources = updated.sources
                self.prepareResult()
            } catch { /* Cancellation discards obsolete snapshots; the next update owns loading state. */ }
        }
    }

    private func prepareResult(debounce: Bool = false) {
        resultTask?.cancel()
        let request = UUID(); requestID = request
        guard let index else { return }
        let query = query, revision = sourceRevision
        if let hit = cache.first(where: { $0.0 == query }) {
            result = hit.1; isLoading = false; return
        }
        result = .empty; isLoading = true
        resultTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(150)) }
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) { try index.result(for: query) }
                let page = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.requestID == request, self.sourceRevision == revision else { return }
                self.cache.insert((query, page), at: 0)
                self.cache = Array(self.cache.prefix(6))
                self.resultBuildCount += 1; self.result = page; self.isLoading = false
            } catch { /* Only cancelled, stale work is discarded. Index queries do not do I/O. */ }
        }
    }
}
