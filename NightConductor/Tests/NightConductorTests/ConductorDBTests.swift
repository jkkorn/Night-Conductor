import SQLite3
import XCTest

@testable import NightConductor

/// The stalled-session query against a small Conductor-shaped database.
/// On a real Mac this database passed 5 GB and a million messages, so the
/// query must only touch recent sessions and their last few messages.
final class ConductorDBTests: XCTestCase {
    private var dir: URL!
    private var dbPath: String { dir.appendingPathComponent("conductor.db").path }
    private var home: String { dir.path }
    private let now = ISO.parse("2026-11-25T12:00:00Z")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ncdb-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("projects/app"),
                                                withIntermediateDirectories: true)
        try exec("""
            CREATE TABLE workspaces (id TEXT PRIMARY KEY, workspace_path TEXT, state TEXT);
            CREATE TABLE sessions (id TEXT PRIMARY KEY, status TEXT, claude_session_id TEXT,
                                   title TEXT, workspace_id TEXT, updated_at TEXT);
            CREATE TABLE session_messages (id TEXT PRIMARY KEY, session_id TEXT, role TEXT,
                                           content TEXT, created_at TEXT);
            CREATE INDEX idx_sm_session ON session_messages(session_id);
            """)
        let path = dir.appendingPathComponent("projects/app").path
        try exec("""
            INSERT INTO workspaces VALUES ('w1', '\(path)', 'ready'), ('w2', '\(path)', 'archived');
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { throw XCTSkip("sqlite open failed") }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            XCTFail("SQL failed: \(message)")
        }
    }

    private static let limitHit = #"{"type":"result","is_error":true,"api_error_status":429}"#
    private static let success = #"{"type":"result","is_error":false}"#

    private func addSession(_ id: String, status: String = "idle", workspace: String = "w1",
                            updatedAt: String, results: [(String, String)], filler: Int = 0) throws {
        let uuid = UUID().uuidString.lowercased()
        try exec("""
            INSERT INTO sessions VALUES ('\(id)', '\(status)', '\(uuid)', 'Refactor onboarding flow',
                                         '\(workspace)', '\(updatedAt)');
            """)
        for (n, (content, at)) in results.enumerated() {
            try exec("INSERT INTO session_messages VALUES ('\(id)-r\(n)', '\(id)', 'assistant', '\(content)', '\(at)');")
        }
        for n in 0..<filler {   // chatter after the last result
            try exec("INSERT INTO session_messages VALUES ('\(id)-f\(n)', '\(id)', 'user', 'not json', '\(updatedAt)');")
        }
    }

    private func stalledIDs() throws -> [String] {
        try ConductorDB.findStalledSessions(dbPath: dbPath, now: now, home: home).map(\.sessionID).sorted()
    }

    // MARK: tests

    func testFindsARecentLimitStall() throws {
        try addSession("s-stalled", updatedAt: "2026-11-25T10:00:00.000Z",
                       results: [(Self.success, "2026-11-25T09:00:00Z"), (Self.limitHit, "2026-11-25T10:00:00Z")])
        XCTAssertEqual(try stalledIDs(), ["s-stalled"])
    }

    func testIgnoresOldWorkingArchivedAndRecoveredSessions() throws {
        try addSession("s-old", updatedAt: "2026-05-24T23:27:55.000Z",
                       results: [(Self.limitHit, "2026-05-24T15:33:03Z")])
        try addSession("s-working", status: "working", updatedAt: "2026-11-25T10:00:00.000Z",
                       results: [(Self.limitHit, "2026-11-25T10:00:00Z")])
        try addSession("s-archived", workspace: "w2", updatedAt: "2026-11-25T10:00:00.000Z",
                       results: [(Self.limitHit, "2026-11-25T10:00:00Z")])
        try addSession("s-recovered", updatedAt: "2026-11-25T11:00:00.000Z",
                       results: [(Self.limitHit, "2026-11-25T10:00:00Z"), (Self.success, "2026-11-25T11:00:00Z")])
        XCTAssertEqual(try stalledIDs(), [])
    }

    func testAcceptsSQLiteStyleTimestampsAndTrailingChatter() throws {
        // Conductor writes both "2026-11-25 10:00:00" and ISO 8601 with a Z.
        try addSession("s-mixed", updatedAt: "2026-11-25 10:05:00",
                       results: [(Self.limitHit, "2026-11-25T10:00:00Z")], filler: 3)
        XCTAssertEqual(try stalledIDs(), ["s-mixed"])
    }
}
