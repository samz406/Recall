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
    private var indexedRows: [String: [String: String]] = [:]
    /// Digest of the saved text already written to `capture_terms`, so a later save can skip unchanged screenshots.
    private var termDigests: [String: String] = [:]

    public init(databaseURL: URL) throws {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
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
            termDigests = try loadTermDigests()
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
        try synchronize(with: state, force: true)
    }

    public func synchronize(with state: RecallState, force: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        let previousRows = indexedRows
        try executeUnlocked("BEGIN IMMEDIATE;")
        do {
            if force {
                for table in ["captures_fts", "episodes_fts", "episodes", "project_states", "user_memories", "insights", "insight_feedback", "learned_routines", "capture_terms", "capture_term_state"] {
                    try executeUnlocked("DELETE FROM \(table);")
                }
                indexedRows = [:]
                termDigests = [:]
            }
            let captureIDs = Set(state.captures.map { $0.id.uuidString })
            for id in Set(termDigests.keys).subtracting(captureIDs) {
                try insert("DELETE FROM capture_terms WHERE capture_id = ?;", [.text(id)])
                try insert("DELETE FROM capture_term_state WHERE capture_id = ?;", [.text(id)])
                termDigests.removeValue(forKey: id)
            }
            try removeMissing("captures_fts", column: "capture_id", ids: captureIDs)
            try removeMissing("episodes", column: "id", ids: Set(state.episodes.map { $0.id.uuidString }))
            try removeMissing("project_states", column: "project_key", ids: Set(state.projects.map(\.projectKey)))
            try removeMissing("user_memories", column: "id", ids: Set(state.userMemories.map { $0.id.uuidString }))
            try removeMissing("insights", column: "id", ids: Set(state.insights.map { $0.id.uuidString }))
            try removeMissing("insight_feedback", column: "id", ids: Set(state.insightFeedback.map { $0.id.uuidString }))
            try removeMissing("learned_routines", column: "id", ids: Set(state.learnedRoutines.map { $0.id.uuidString }))
            for capture in state.captures {
                let id = capture.id.uuidString
                if try changed("captures_fts", column: "capture_id", id: id, payload: json(capture)) {
                    try insert(
                        "INSERT INTO captures_fts(capture_id, content, app_name, window_title, tags) VALUES (?, ?, ?, ?, ?);",
                        [.text(id), .text(capture.ocrText), .text(capture.sourceAppName ?? ""), .text(capture.windowTitle ?? ""), .text(capture.tags.joined(separator: " "))]
                    )
                    try writeTerms(for: capture)
                } else if termDigests[id] == nil {
                    try writeTerms(for: capture)
                }
            }
            for episode in state.episodes {
                guard try changed("episodes", column: "id", id: episode.id.uuidString, payload: json(episode)) else { continue }
                try insert("DELETE FROM episodes_fts WHERE episode_id = ?;", [.text(episode.id.uuidString)])
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
                guard try changed("project_states", column: "project_key", id: project.projectKey, payload: json(project)) else { continue }
                try insert(
                    "INSERT INTO project_states(project_key, payload, updated_at) VALUES (?, ?, ?);",
                    [.text(project.projectKey), .text(json(project)), .double(project.updatedAt.timeIntervalSince1970)]
                )
            }
            for memory in state.userMemories {
                guard try changed("user_memories", column: "id", id: memory.id.uuidString, payload: json(memory)) else { continue }
                try insert(
                    "INSERT INTO user_memories(id, memory_key, kind, status, content, confidence, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                    [.text(memory.id.uuidString), .text(memory.key), .text(memory.kind.rawValue), .text(memory.status.rawValue), .text(memory.content), .double(memory.confidence), .text(json(memory)), .double(memory.updatedAt.timeIntervalSince1970)]
                )
            }
            for insight in state.insights {
                guard try changed("insights", column: "id", id: insight.id.uuidString, payload: json(insight)) else { continue }
                try insert(
                    "INSERT INTO insights(id, day, kind, title, detail, confidence, score, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                    [.text(insight.id.uuidString), .double(insight.day.timeIntervalSince1970), .text(insight.kind.rawValue), .text(insight.title), .text(insight.detail), .double(insight.confidence), .double(insight.interventionScore), .text(json(insight))]
                )
            }
            for item in state.insightFeedback {
                guard try changed("insight_feedback", column: "id", id: item.id.uuidString, payload: json(item)) else { continue }
                try insert(
                    "INSERT INTO insight_feedback(id, insight_id, kind, rating, created_at) VALUES (?, ?, ?, ?, ?);",
                    [.text(item.id.uuidString), .text(item.insightID.uuidString), .text(item.insightKind.rawValue), .text(item.rating.rawValue), .double(item.createdAt.timeIntervalSince1970)]
                )
            }
            for routine in state.learnedRoutines {
                guard try changed("learned_routines", column: "id", id: routine.id.uuidString, payload: json(routine)) else { continue }
                try insert(
                    "INSERT INTO learned_routines(id, routine_key, status, title, payload, updated_at) VALUES (?, ?, ?, ?, ?, ?);",
                    [.text(routine.id.uuidString), .text(routine.key), .text(routine.status.rawValue), .text(routine.title), .text(json(routine)), .double(routine.updatedAt.timeIntervalSince1970)]
                )
            }
            try executeUnlocked("COMMIT;")
        } catch {
            try? executeUnlocked("ROLLBACK;")
            indexedRows = previousRows
            throw error
        }
    }

    private func changed(_ table: String, column: String, id: String, payload: String) throws -> Bool {
        guard indexedRows[table]?[id] != payload else { return false }
        try insert("DELETE FROM \(table) WHERE \(column) = ?;", [.text(id)])
        indexedRows[table, default: [:]][id] = payload
        return true
    }

    private func removeMissing(_ table: String, column: String, ids: Set<String>) throws {
        let removed = (indexedRows[table] ?? [:]).keys.filter { !ids.contains($0) }
        for id in removed {
            try insert("DELETE FROM \(table) WHERE \(column) = ?;", [.text(id)])
            if table == "episodes" { try insert("DELETE FROM episodes_fts WHERE episode_id = ?;", [.text(id)]) }
            indexedRows[table]?.removeValue(forKey: id)
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
}

/// Saved-text lookup. Built when a screenshot's text is stored, then reused by 问一问.
public struct CaptureTextIndex: Sendable {
    private let index: SQLiteIntelligenceIndex
    init(index: SQLiteIntelligenceIndex) { self.index = index }
    public func ids(matching terms: [String], start: Date? = nil, end: Date? = nil, limit: Int = 80) -> [UUID] {
        (try? index.captureIDs(matchingTerms: terms, start: start, end: end, limit: limit)) ?? []
    }
}

extension SQLiteIntelligenceIndex {
    /// Capture IDs whose saved text contains the question terms. The terms were stored when the text was saved.
    public func captureIDs(matchingTerms terms: [String], start: Date? = nil, end: Date? = nil, limit: Int = 80) throws -> [UUID] {
        let lookup = QuestionTerms.termLookup(terms)
        guard !lookup.groups.isEmpty || !lookup.words.isEmpty else { return [] }
        let startValue = start?.timeIntervalSince1970
        let endValue = end?.timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        var matched: [String: Double] = [:]
        func absorb(_ rows: [String: Double]) {
            for (id, created) in rows { matched[id] = created }
        }
        for group in lookup.groups {
            absorb(try intersectTerms(group, start: startValue, end: endValue))
        }
        for word in lookup.words {
            absorb(try posting(word, start: startValue, end: endValue))
        }
        return matched.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(max(limit, 1))
            .compactMap { UUID(uuidString: $0.key) }
    }

    private func writeTerms(for capture: CaptureRecord) throws {
        let id = capture.id.uuidString
        let searchable = [capture.correctedText ?? capture.ocrText, capture.summary ?? "", capture.sourceAppName ?? "", capture.windowTitle ?? "", capture.tags.joined(separator: " ")]
            .joined(separator: " ")
        let digest = CaptureUnderstandingEngine.digest(searchable)
        guard termDigests[id] != digest else { return }
        try insert("DELETE FROM capture_terms WHERE capture_id = ?;", [.text(id)])
        let created = capture.createdAt.timeIntervalSince1970
        let terms = QuestionTerms.documentTerms(searchable)
        if !terms.isEmpty {
            guard let database else { throw SQLiteIntelligenceError.open("database closed") }
            var statement: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO capture_terms(term, capture_id, created_at) VALUES (?, ?, ?);"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw SQLiteIntelligenceError.prepare(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            for term in terms {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(.text(term), to: statement, at: 1)
                bind(.text(id), to: statement, at: 2)
                bind(.double(created), to: statement, at: 3)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw SQLiteIntelligenceError.execute(String(cString: sqlite3_errmsg(database)))
                }
            }
        }
        try insert(
            "INSERT OR REPLACE INTO capture_term_state(capture_id, digest) VALUES (?, ?);",
            [.text(id), .text(digest)]
        )
        termDigests[id] = digest
    }

    private func posting(_ term: String, start: Double?, end: Double?) throws -> [String: Double] {
        var sql = "SELECT capture_id, created_at FROM capture_terms WHERE term = ?"
        var values: [SQLiteValue] = [.text(term)]
        if let start { sql += " AND created_at >= ?"; values.append(.double(start)) }
        if let end { sql += " AND created_at <= ?"; values.append(.double(end)) }
        sql += " ORDER BY created_at DESC LIMIT 4000;"
        return try rows(sql, values)
    }

    private func intersectTerms(_ terms: [String], start: Double?, end: Double?) throws -> [String: Double] {
        guard let first = terms.first else { return [:] }
        var current = try posting(first, start: start, end: end)
        for term in terms.dropFirst() {
            guard !current.isEmpty else { break }
            let next = try posting(term, start: start, end: end)
            current = current.filter { next[$0.key] != nil }
        }
        return current
    }

    private func rows(_ sql: String, _ values: [SQLiteValue]) throws -> [String: Double] {
        guard let database else { return [:] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteIntelligenceError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { bind(value, to: statement, at: Int32(offset + 1)) }
        var result: [String: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            result[String(cString: text)] = sqlite3_column_double(statement, 1)
        }
        return result
    }

    private func loadTermDigests() throws -> [String: String] {
        guard let database else { return [:] }
        var statement: OpaquePointer?
        let sql = "SELECT capture_id, digest FROM capture_term_state;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteIntelligenceError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let digest = sqlite3_column_text(statement, 1) else { continue }
            result[String(cString: id)] = String(cString: digest)
        }
        return result
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
        CREATE TABLE IF NOT EXISTS capture_terms(term TEXT NOT NULL, capture_id TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(term, capture_id));
        CREATE INDEX IF NOT EXISTS capture_terms_lookup ON capture_terms(term, created_at);
        CREATE TABLE IF NOT EXISTS capture_term_state(capture_id TEXT PRIMARY KEY, digest TEXT NOT NULL);
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
