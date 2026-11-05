import Foundation

public struct FileCleanupResult: Sendable {
    public let removedCount: Int
    public let pendingCount: Int
}

extension FileMemoryStore {
    public func setKeepText(id: UUID, enabled: Bool) throws {
        guard let i = state.captures.firstIndex(where: { $0.id == id }) else { return }
        let before = state
        state.captures[i].keepTextIndefinitely = enabled
        do { try persistReviewState() } catch { state = before; throw error }
    }
    public func recoveryBackups() -> [ArchiveBackup] { ArchiveReliability.backups(storage) }
    public func retryArchiveBackup() throws {
        // A normal state write creates a fresh mirror and cannot reintroduce an old source.
        try persistReviewState()
    }
    func queueDeletedScreenshots(_ paths: [String]) {
        let deleted = paths.map { "Recently Deleted/Screenshots/" + URL(fileURLWithPath: $0).lastPathComponent }
        state.pendingFileDeletions = ((state.pendingFileDeletions ?? []) + deleted).memoryUnique()
    }
    func managedScreenshotFiles() -> [String] {
        ["Screenshots", "Recently Deleted/Screenshots"].flatMap { folder -> [String] in
            let url = storage.rootURL.appendingPathComponent(folder)
            return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).map { folder + "/" + $0.lastPathComponent }
        }
    }
    /// A recording can fail before its JSON write. Discover its otherwise untracked image later.
    /// The grace period protects captures currently between screenshot and OCR/persistence.
    @discardableResult
    public func queueOrphanScreenshots(now: Date = .now) throws -> Int {
        let active = Set(state.captures.compactMap(\.imageRelativePath) + state.memoryKnowledge.pendingScreenshotDeletions)
        let deleted = Set(state.recentlyDeletedMemories.flatMap(\.screenshotPaths).map { "Recently Deleted/Screenshots/" + URL(fileURLWithPath: $0).lastPathComponent })
        let known = active.union(deleted).union(state.pendingFileDeletions ?? [])
        var orphans: [String] = []
        for folder in ["Screenshots", "Recently Deleted/Screenshots"] {
            let parent = storage.rootURL.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: parent.path) else { continue }
            guard try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            for url in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
                let path = folder + "/" + url.lastPathComponent
                guard url.pathExtension == "png", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil, !known.contains(path) else { continue }
                let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard attributes.isRegularFile == true, let modified = attributes.contentModificationDate,
                      now.timeIntervalSince(modified) > 15 * 60 else { continue }
                orphans.append(path)
            }
        }
        guard !orphans.isEmpty else { return 0 }
        let before = state
        state.pendingFileDeletions = ((state.pendingFileDeletions ?? []) + orphans).memoryUnique()
        do { try persistReviewState() } catch { state = before; throw error }
        return orphans.count
    }
    /// Persist the queue before deleting bytes. Every operation is idempotent after a crash/restart.
    @discardableResult
    public func retryPendingFileCleanup() throws -> FileCleanupResult {
        let before = state
        let paths = state.pendingFileDeletions ?? []
        var remaining: [String] = [], removed = 0
        for path in paths {
            do {
                let url = storage.rootURL.appendingPathComponent(path).standardizedFileURL
                let parent = url.deletingLastPathComponent()
                let allowed = [storage.screenshotsURL.standardizedFileURL, storage.recentlyDeletedScreenshotsURL.standardizedFileURL]
                guard allowed.contains(parent), url.pathExtension == "png",
                      try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ArchiveReliabilityError.invalidBackup }
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                removed += 1
            } catch { remaining.append(path) }
        }
        state.pendingFileDeletions = remaining
        if state.pendingRecoveryCleanup == true {
            do { try ArchiveReliability.discardHistory(storage); state.pendingRecoveryCleanup = false }
            catch { state.pendingRecoveryCleanup = true }
        }
        if remaining != paths || state.pendingRecoveryCleanup != before.pendingRecoveryCleanup {
            do { try persistReviewState() } catch { state = before; throw error }
        }
        return FileCleanupResult(removedCount: removed, pendingCount: remaining.count + (state.pendingRecoveryCleanup == true ? 1 : 0))
    }
}
