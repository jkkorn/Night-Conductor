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
/// "stalled" when its most recent message is a 429 usage-limit error —
/// it died at the limit and nothing has happened since.
enum ConductorDB {
    static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/com.conductor.app/conductor.db"
    }

    private static let lastMessageQuery = """
    WITH last_msgs AS (
        SELECT session_id, content, created_at,
               ROW_NUMBER() OVER (
                   PARTITION BY session_id ORDER BY created_at DESC
               ) AS rn
        FROM session_messages
    )
    SELECT s.id, s.claude_session_id, s.title, w.workspace_path,
           lm.content, lm.created_at
    FROM last_msgs lm
    JOIN sessions s ON s.id = lm.session_id
    JOIN workspaces w ON w.id = s.workspace_id
    WHERE lm.rn = 1
      AND w.state = 'active'
      AND lm.content LIKE '%api_error_status%'
    """

    static func findStalledSessions(dbPath: String = defaultPath) throws -> [StalledSession] {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ConductorDBError.notFound(dbPath)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ConductorDBError.sqlite("cannot open read-only")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, lastMessageQuery, -1, &statement, nil) == SQLITE_OK else {
            throw ConductorDBError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [StalledSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let session = parseRow(statement) {
                sessions.append(session)
            }
        }
        return sessions
    }

    private static func parseRow(_ statement: OpaquePointer?) -> StalledSession? {
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

        return StalledSession(
            sessionID: sessionID,
            claudeSessionID: claudeSessionID,
            title: column(2) ?? "Untitled",
            workspacePath: workspacePath,
            errorText: payload["result"] as? String ?? "",
            stalledAt: column(5).flatMap(ISO.parse)
        )
    }
}
