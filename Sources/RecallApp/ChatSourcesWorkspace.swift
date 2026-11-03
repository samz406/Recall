import Foundation
import Combine
import RecallKit

/// Reuse source lookup across messages and unrelated published UI changes.
@MainActor
final class ChatSourcesWorkspace: ObservableObject {
    @Published private(set) var revision = UUID()
    private var captures: [CaptureRecord] = []
    private var excluded = Set<String>()
    private var invalid = Set<UUID>()
    private var index = ChatSourceIndex(captures: [])
    private var cachedIDs: [([UUID], [UUID])] = []
    private(set) var buildCount = 0

    func update(_ state: RecallState) {
        let invalid = Set(state.matterCorrections.filter { $0.kind == .notMine || $0.kind == .inaccurate }.flatMap(\.evidenceIDs))
        let excluded = state.privacy.excludedBundleIdentifiers
        guard captures != state.captures || self.excluded != excluded || self.invalid != invalid else { return }
        captures = state.captures; self.excluded = excluded; self.invalid = invalid
        index = ChatSourceIndex(captures: EvidenceAccess.records(state))
        cachedIDs.removeAll(); buildCount += 1; revision = UUID()
    }
    func availableIDs(_ citations: [UUID]) -> [UUID] {
        if let hit = cachedIDs.first(where: { $0.0 == citations }) { return hit.1 }
        let ids = index.availableIDs(citations)
        cachedIDs.insert((citations, ids), at: 0); cachedIDs = Array(cachedIDs.prefix(8))
        return ids
    }
    func record(id: UUID) -> CaptureRecord? { index.record(id: id) }
    func snapshot() -> ChatSourceIndex { index }
}
