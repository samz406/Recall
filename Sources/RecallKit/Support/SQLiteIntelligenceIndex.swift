import CSQLite
import Foundation

public enum SQLiteIntelligenceError: LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): "无法打开本地智能索引：\(message)"
        case .execute(let message): "无法更新本地智能索引：\(message)"
        case .prepare(let message): "无法查询本地智能索引：\(message)"
        }
    }
}

/// SQLite 是可重建的本地检索与结构化投影；`recall-state.json` 继续承担兼容备份。
/// 数据库启用 WAL 和 FTS5，失败时 FileMemoryStore 会自动回退到原有内存检索。
public final class SQLiteIntelligenceIndex: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(databaseURL: URL) throws {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let pointer { sqlite3_close(pointer) }
            throw SQLiteIntelligenceError.open(message)
        }
        database = pointer
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("PRAGMA foreign_keys=ON;")
            try createSchema()
        } catch {
            sqlite3_close(pointer)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func replace(with state: RecallState) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked("BEGIN IMMEDIATE;")
        do {
            for table in ["captures_fts", "episodes_fts", "episodes", "project_states", "user_memories", "insights", "insight_feedback", "learned_routines"] {
                try executeUnlocked("DELETE FROM \(table);")
            }
            for capture in state.captures {
                try insert(
                    "INSERT INTO captures_fts(capture_id, content, app_name, window_title, tags) VALUES (?, ?, ?, ?, ?);",
                    [.text(capture.id.uuidString), .text(capture.ocrText), .text(capture.sourceAppName ?? ""), .text(capture.windowTitle ?? ""), .text(capture.tags.joined(separator: " "))]
                )
            }
            for episode in state.episodes {
                try insert(
                    "INSERT INTO episodes(id, day, started_at, ended_at, project_key, project_name, title, intent, action, outcome, next_action, status, importance, confidence, evidence_ids) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
                    [
                        .text(episode.id.uuidString), .double(episode.day.timeIntervalSince1970), .double(episode.startedAt.timeIntervalSince1970),
                        .double(episode.endedAt.timeIntervalSince1970), .text(episode.projectKey), .text(episode.projectName), .text(episode.title),
                        .text(episode.intent), .text(episode.action), .text(episode.outcome ?? ""), .text(episode.nextAction ?? ""),
                        .text(episode.status.rawValue), .double(episode.importance), .double(episode.confidence), .text(json(episode.evidenceIDs))
                    ]
                )
                try insert(
                    "INSERT INTO episodes_fts(episode_id, project_name, title, content) VALUES (?, ?, ?, ?);",
                    [.text(episode.id.uuidString), .text(episode.projectName), .text(episode.title), .text([episode.intent, episode.action, episode.outcome ?? "", episode.nextAction ?? ""].joined(separator: " "))]
                )
            }
            for project in state.projects {
                try insert(
                    "INSERT INTO project_states(project_key, payload, updated_at) VALUES (?, ?, ?);",
                    [.text(project.projectKey), .text(json(project)), .double(project.updatedAt.timeIntervalSince1970)]
                )
            }
            for memory in state.userMemories {
                try insert(
                    "INSERT INTO user_memories(id, memory_key, kind, status, content, confidence, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                    [.text(memory.id.uuidString), .text(memory.key), .text(memory.kind.rawValue), .text(memory.status.rawValue), .text(memory.content), .double(memory.confidence), .text(json(memory)), .double(memory.updatedAt.timeIntervalSince1970)]
                )
            }
            for insight in state.insights {
                try insert(
                    "INSERT INTO insights(id, day, kind, title, detail, confidence, score, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                    [.text(insight.id.uuidString), .double(insight.day.timeIntervalSince1970), .text(insight.kind.rawValue), .text(insight.title), .text(insight.detail), .double(insight.confidence), .double(insight.interventionScore), .text(json(insight))]
                )
            }
            for item in state.insightFeedback {
                try insert(
                    "INSERT INTO insight_feedback(id, insight_id, kind, rating, created_at) VALUES (?, ?, ?, ?, ?);",
                    [.text(item.id.uuidString), .text(item.insightID.uuidString), .text(item.insightKind.rawValue), .text(item.rating.rawValue), .double(item.createdAt.timeIntervalSince1970)]
                )
            }
            for routine in state.learnedRoutines {
                try insert(
                    "INSERT INTO learned_routines(id, routine_key, status, title, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
                    [.text(routine.id.uuidString), .text(routine.key), .text(routine.status.rawValue), .text(routine.title), .text(json(routine)), .double(routine.updatedAt.timeIntervalSince1970)]
                )
            }
            try executeUnlocked("COMMIT;")
        } catch {
            try? executeUnlocked("ROLLBACK;")
            throw error
        }
    }

    public func searchCaptureIDs(matching query: String, limit: Int = 12) throws -> [UUID] {
        let terms = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
            .filter { $0.count > 1 }
        guard !terms.isEmpty else { return [] }
        let ftsQuery = terms.prefix(8).map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT capture_id FROM captures_fts WHERE captures_fts MATCH ? ORDER BY rank LIMIT ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteIntelligenceError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        bind(.text(ftsQuery), to: statement, at: 1)
        bind(.int(Int64(max(limit, 1))), to: statement, at: 2)
        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) else { continue }
            ids.append(id)
        }
        return ids
    }

    private func createSchema() throws {
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(capture_id UNINDEXED, content, app_name, window_title, tags, tokenize='unicode61');
        CREATE TABLE IF NOT EXISTS episodes(id TEXT PRIMARY KEY, day REAL, started_at REAL, ended_at REAL, project_key TEXT, project_name TEXT, title TEXT, intent TEXT, action TEXT, outcome TEXT, next_action TEXT, status TEXT, importance REAL, confidence REAL, evidence_ids TEXT);
        CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts USING fts5(episode_id UNINDEXED, project_name, title, content, tokenize='unicode61');
        CREATE TABLE IF NOT EXISTS project_states(project_key TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS user_memories(id TEXT PRIMARY KEY, memory_key TEXT UNIQUE, kind TEXT, status TEXT, content TEXT, confidence REAL, payload TEXT, updated_at REAL);
        CREATE TABLE IF NOT EXISTS insights(id TEXT PRIMARY KEY, day REAL, kind TEXT, title TEXT, detail TEXT, confidence REAL, score REAL, payload TEXT);
        CREATE TABLE IF NOT EXISTS insight_feedback(id TEXT PRIMARY KEY, insight_id TEXT, kind TEXT, rating TEXT, created_at REAL);
        CREATE TABLE IF NOT EXISTS learned_routines(id TEXT PRIMARY KEY, routine_key TEXT UNIQUE, status TEXT, title TEXT, payload TEXT, updated_at REAL);
        """)
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked(sql)
    }

    private func executeUnlocked(_ sql: String) throws {
        guard let database else { throw SQLiteIntelligenceError.open("database closed") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw SQLiteIntelligenceError.execute(message)
        }
    }

    private func insert(_ sql: String, _ values: [SQLiteValue]) throws {
        guard let database else { throw SQLiteIntelligenceError.open("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteIntelligenceError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteIntelligenceError.execute(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) {
        switch value {
        case .text(let text):
            _ = text.withCString { pointer in
                sqlite3_bind_text(statement, index, pointer, -1, Self.transient)
            }
        case .double(let value): sqlite3_bind_double(statement, index, value)
        case .int(let value): sqlite3_bind_int64(statement, index, value)
        }
    }

    private func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private enum SQLiteValue {
    case text(String)
    case double(Double)
    case int(Int64)
}
