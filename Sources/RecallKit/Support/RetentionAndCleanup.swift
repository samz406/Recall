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
