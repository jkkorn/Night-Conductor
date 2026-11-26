import Foundation
import SQLite3

enum ConductorDBError: LocalizedError {
    case notFound(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "Conductor database not found at \(p)"
        case .sqlite(let m): return "SQLite: \(m)"
        }
    }
}

/// Read-only scanner for Conductor's session database. A session is
/// "stalled" when its most recent *result-type* message is a 429
/// usage-limit error. (After a 429, Conductor appends synthetic assistant
/// and system messages, so the error is rarely the literal last row.)
enum ConductorDB {
    static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/com.conductor.app/conductor.db"
    }

    private static let maxStallAge = StalledSession.maxAge

    /// The last `result` of each recently active, non-working session in a
    /// live workspace, kept only when it was a usage-limit error.
    ///
    /// Conductor's database grows without bound (5 GB and a million messages
    /// on a real Mac), and nothing indexes messages by time. The old query
    /// ranked every message ever written, reading all their text: 85 seconds
    /// per run, started every 30 seconds. This one:
    /// - only looks at sessions touched since the cutoff (`?1`, the oldest
    ///   stall we'd still resume; older ones were discarded anyway), and
    /// - in each, only the newest 40 messages, found through the session
    ///   index by insertion order, before reading any message text.
    /// A stall's result is one of its last messages, so nothing real is lost.
    private static let lastResultQuery = """
    WITH candidates AS (
        SELECT s.id, s.claude_session_id, s.title, w.workspace_path
        FROM sessions s
        JOIN workspaces w ON w.id = s.workspace_id
        WHERE w.state != 'archived'
          AND s.status != 'working'
          AND julianday(s.updated_at) >= julianday(?1)
    )
    SELECT c.id, c.claude_session_id, c.title, c.workspace_path,
           m.content, m.created_at
    FROM candidates c
    JOIN session_messages m ON m.rowid = (
        SELECT r.rowid FROM session_messages r
        WHERE r.rowid IN (
            SELECT rowid FROM session_messages
            WHERE session_id = c.id
            ORDER BY rowid DESC LIMIT 40
        )
          AND json_valid(r.content)
          AND json_extract(r.content, '$.type') = 'result'
        ORDER BY r.rowid DESC LIMIT 1
    )
    WHERE json_extract(m.content, '$.is_error') = 1
      AND json_extract(m.content, '$.api_error_status') = 429
    """

    /// Current status of a session ('working', 'idle', 'error', …).
    static func sessionStatus(
        _ sessionID: String, dbPath: String = defaultPath
    ) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ConductorDBError.sqlite("cannot open read-only")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT status FROM sessions WHERE id = ?", -1, &statement, nil
        ) == SQLITE_OK else {
            throw ConductorDBError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: text)
    }

    static func findStalledSessions(
        dbPath: String = defaultPath, now: Date = Date(), home: String = NSHomeDirectory()
    ) throws -> [StalledSession] {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ConductorDBError.notFound(dbPath)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ConductorDBError.sqlite("cannot open read-only")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, lastResultQuery, -1, &statement, nil) == SQLITE_OK else {
            throw ConductorDBError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let cutoff = ISO8601DateFormatter().string(from: now.addingTimeInterval(-maxStallAge))
        sqlite3_bind_text(statement, 1, cutoff, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var sessions: [StalledSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let session = parseRow(statement, now: now, home: home) {
                sessions.append(session)
            }
        }
        return sessions
    }

    private static func parseRow(_ statement: OpaquePointer?, now: Date, home: String) -> StalledSession? {
        func column(_ index: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: text)
        }
        guard
            let sessionID = column(0),
            let claudeSessionID = column(1), !claudeSessionID.isEmpty,
            let workspacePath = column(3), !workspacePath.isEmpty,
            let content = column(4)
        else { return nil }

        guard
            let data = content.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            payload["type"] as? String == "result",
            payload["is_error"] as? Bool == true,
            (payload["api_error_status"] as? NSNumber)?.intValue == 429
        else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil } // workspace was removed; nothing to resume into
        // Untrusted row: only a UUID session in a real project folder.
        guard ResumeSafety.isValidSessionID(claudeSessionID),
              ResumeSafety.isSafeWorkspace(workspacePath, home: home)
        else { return nil }

        // Fail closed: an unparseable timestamp must not bypass the
        // staleness guard and let an arbitrarily old session be resumed.
        guard let stalledAt = column(5).flatMap(ISO.parse) else { return nil }
        if now.timeIntervalSince(stalledAt) > maxStallAge {
            return nil // too old; the user has moved on
        }

        return StalledSession(
            sessionID: sessionID,
            claudeSessionID: claudeSessionID,
            title: column(2) ?? "Untitled",
            workspacePath: workspacePath,
            errorText: payload["result"] as? String ?? "",
            stalledAt: stalledAt
        )
    }
}
