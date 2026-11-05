import Foundation
import CryptoKit
import Darwin

public enum ArchiveReliabilityError: LocalizedError {
    case busy, changedExternally, invalidBackup, invalidArchive, missingPrimary, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: RecallLocalization.both("本地档案结构不完整，原始文件已保留。", "The local archive is incomplete. The original file is preserved.")
        case .missingPrimary: RecallLocalization.both("原始档案缺失，请从已校验的备份恢复。", "The primary archive is missing. Restore a verified backup.")
        case .busy: RecallLocalization.both("记忆库正被另一项操作使用，请稍后重试。", "The archive is busy. Please retry shortly.")
        case .changedExternally: RecallLocalization.both("本地档案已发生变化。请重新打开应用，以免覆盖新记录。", "The archive changed outside this operation. Reopen Recall to avoid overwriting newer records.")
        case .invalidBackup: RecallLocalization.both("备份校验失败，原始文件未修改。", "Backup validation failed. The original file was not changed.")
        case .unsupportedVersion: RecallLocalization.both("此记忆库来自更新版本，请更新 Recall 后再打开。", "This archive requires a newer version of Recall.")
        }
    }
}

public struct ArchiveBackup: Identifiable, Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var captureCount: Int
    public init(id: String, createdAt: Date, captureCount: Int) {
        self.id = id; self.createdAt = createdAt; self.captureCount = captureCount
    }
}

/// One verified mirror, not an accumulating history of deleted personal data.
/// Primary writes remain atomic. A failed mirror never turns a committed record into a failed save.
public enum ArchiveReliability {
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private struct Skipped: Decodable { init(from decoder: Decoder) throws {} }
    private struct Header: Decodable {
        var schemaVersion: Int?
        var captures: [Skipped]?
        enum CodingKeys: String, CodingKey { case schemaVersion, captures }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try? container.decode(Int.self, forKey: .schemaVersion)
            captures = try? container.decode([Skipped].self, forKey: .captures)
        }
    }
    public static func decode(_ data: Data) throws -> RecallState {
        // Check the format before RecallState's compatibility decoder converts a future schema
        // into a generic source-change error. The recovery page needs the explicit upgrade reason.
        // A header decode avoids building two full object graphs of a large archive.
        let header = try? JSONDecoder().decode(Header.self, from: data)
        if let version = header?.schemaVersion, !(1...2).contains(version) {
            throw ArchiveReliabilityError.unsupportedVersion
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(RecallState.self, from: data)
        guard (1...2).contains(state.schemaVersion) else { throw ArchiveReliabilityError.unsupportedVersion }
        guard header?.captures != nil,
              Set(state.captures.map(\.id)).count == state.captures.count,
              Set(state.messages.map(\.id)).count == state.messages.count,
              Set(state.reminders.map(\.id)).count == state.reminders.count,
              Set(state.rules.map(\.id)).count == state.rules.count,
              Set(state.dailySummaries.map(\.id)).count == state.dailySummaries.count,
              Set(state.weeklyReports.map(\.id)).count == state.weeklyReports.count else { throw ArchiveReliabilityError.invalidArchive }
        return state
    }
    static func directory(_ storage: RecallStorage) -> URL { storage.rootURL.appendingPathComponent("Recovery", isDirectory: true) }
    static func exclusive<T>(_ storage: RecallStorage, _ work: () throws -> T) throws -> T {
        let path = storage.rootURL.appendingPathComponent("archive.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ArchiveReliabilityError.busy }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ArchiveReliabilityError.busy }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try work()
    }
    @discardableResult
    static func write(_ data: Data, storage: RecallStorage, expectedDigest: String? = nil, requireMissing: Bool = false) throws -> Bool {
        try exclusive(storage) {
            if requireMissing, FileManager.default.fileExists(atPath: storage.stateURL.path) { throw ArchiveReliabilityError.changedExternally }
            if let expectedDigest {
                let existing = try Data(contentsOf: storage.stateURL)
                guard digest(existing) == expectedDigest else { throw ArchiveReliabilityError.changedExternally }
            }
            let folder = directory(storage)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Invalidate the old mirror BEFORE replacing primary. A crash can never offer a pre-deletion backup.
            for url in try managedMirrors(storage) { try FileManager.default.removeItem(at: url) }
            try data.write(to: storage.stateURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storage.stateURL.path)
            let backup = folder.appendingPathComponent("latest-" + digest(data) + ".json")
            do {
                try data.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                return true
            } catch { return false }
        }
    }
    static func managedMirrors(_ storage: RecallStorage) throws -> [URL] {
        let folder = directory(storage)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ArchiveReliabilityError.invalidBackup }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("latest-") && $0.pathExtension == "json" }
    }
    public static func backups(_ storage: RecallStorage) -> [ArchiveBackup] {
        ((try? managedMirrors(storage)) ?? []).compactMap { url in
            guard let data = try? checkedBackup(url), let state = try? decode(data), state.llmConfiguration.apiKey.isEmpty else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ArchiveBackup(id: url.lastPathComponent, createdAt: date, captureCount: state.captures.count)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private static func checkedBackup(_ url: URL) throws -> Data {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ArchiveReliabilityError.invalidBackup }
        let data = try Data(contentsOf: url)
        guard url.lastPathComponent == "latest-" + digest(data) + ".json" else { throw ArchiveReliabilityError.invalidBackup }
        return data
    }
    /// User-initiated only. Damaged bytes are isolated before replacement; no blank archive fallback.
    public static func restore(_ backup: ArchiveBackup, storage: RecallStorage) throws {
        try exclusive(storage) {
            guard backup.id == URL(fileURLWithPath: backup.id).lastPathComponent,
                  try managedMirrors(storage).contains(where: { $0.lastPathComponent == backup.id }) else { throw ArchiveReliabilityError.invalidBackup }
            let data = try checkedBackup(directory(storage).appendingPathComponent(backup.id))
            let state = try decode(data)
            guard state.llmConfiguration.apiKey.isEmpty else { throw ArchiveReliabilityError.invalidBackup }
            let damaged = storage.rootURL.appendingPathComponent("Damaged Archives", isDirectory: true)
            try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var isolated: URL?
            if FileManager.default.fileExists(atPath: storage.stateURL.path) {
                let destination = damaged.appendingPathComponent(UUID().uuidString + ".bin")
                // Move the original inode instead of making another plaintext copy of a potentially
                // pre-migration archive. The original remains available if replacement fails.
                try FileManager.default.moveItem(at: storage.stateURL, to: destination)
                isolated = destination
            }
            do {
                try data.write(to: storage.stateURL, options: .atomic)
                // A restored archive is the schedule source of truth. A newer sidecar would put the old plan back.
                if FileManager.default.fileExists(atPath: storage.reviewSchedulesURL.path) {
                    try FileManager.default.removeItem(at: storage.reviewSchedulesURL)
                }
            } catch {
                if let isolated, !FileManager.default.fileExists(atPath: storage.stateURL.path) {
                    try? FileManager.default.moveItem(at: isolated, to: storage.stateURL)
                }
                throw error
            }
        }
    }
    /// Remove application-managed legacy copies and damaged archives when content is withdrawn.
    static func discardHistory(_ storage: RecallStorage) throws {
        for url in try FileManager.default.contentsOfDirectory(at: storage.rootURL, includingPropertiesForKeys: nil) {
            if url.lastPathComponent == "Damaged Archives" || (url.lastPathComponent.hasPrefix("recall-state.backup-") && url.pathExtension == "json") {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
