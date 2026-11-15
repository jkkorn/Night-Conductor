import XCTest

@testable import NightConductor

final class ClaudeCodeTests: XCTestCase {
    private let now = ISO.parse("2026-06-15T11:00:00Z")!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nc-cc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `root` doubles as a fake home: transcripts live in root/projects and
    /// the default workspace is root/code/app, a real project folder under it.
    private var projects: URL { root.appendingPathComponent("projects") }
    private var workspace: URL { root.appendingPathComponent("code/app") }

    /// Stable fake UUID per readable name, since session ids must be UUIDs.
    private func id(_ name: String) -> String {
        let hex = name.unicodeScalars.map { String(format: "%02x", $0.value % 256) }.joined()
        let padded = (hex + String(repeating: "0", count: 32)).prefix(32)
        let c = Array(padded)
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))"
    }

    private func scan() -> [StalledSession] {
        ClaudeCodeDB.findStalledSessions(root: projects.path, now: now,
                                         home: root.resolvingSymlinksInPath().path)
    }

    /// Write <uuid>.jsonl in the project dir Claude Code would use for `cwd`
    /// (cwd encoded with non-alphanumerics as "-"), so the cwd check passes.
    private func seed(uuid name: String, lines: [String], cwd: String? = nil) throws {
        let dir = cwd ?? workspace.resolvingSymlinksInPath().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoded = dir.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let proj = projects.appendingPathComponent(encoded)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let uuid = id(name)
        let withCwd = lines.map { $0.replacingOccurrences(of: "__CWD__", with: dir) }
        try withCwd.joined(separator: "\n")
            .write(to: proj.appendingPathComponent("\(uuid).jsonl"), atomically: true, encoding: .utf8)
    }

    private func userLine() -> String {
        #"{"type":"user","cwd":"__CWD__","message":{"role":"user","content":"Fix the build"},"timestamp":"2026-06-15T10:00:00.000Z"}"#
    }
    private func okAssistant() -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]},"timestamp":"2026-06-15T10:05:00.000Z"}"#
    }
    private func errorAssistant() -> String {
        #"{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"message":{"role":"assistant","content":[{"type":"text","text":"You've hit your usage limit · resets 1pm"}]},"timestamp":"2026-06-15T10:10:00.000Z"}"#
    }

    func testDetectsTerminalSessionStalledOnLimit() throws {
        try seed(uuid: "u1", lines: [userLine(), okAssistant(), errorAssistant()])
        let stalled = scan()
        XCTAssertEqual(stalled.count, 1)
        XCTAssertEqual(stalled.first?.claudeSessionID, id("u1"))
        XCTAssertEqual(stalled.first?.source, .claudeCode)
        XCTAssertEqual(stalled.first?.title, "Fix the build")
    }

    func testIgnoresRecoveredTerminalSession() throws {
        try seed(uuid: "u2", lines: [userLine(), errorAssistant(), okAssistant()])
        XCTAssertTrue(scan().isEmpty)
    }

    func testIgnoresMissingWorkspace() throws {
        try seed(uuid: "u3", lines: [userLine(), errorAssistant()], cwd: "/no/such/dir")
        XCTAssertTrue(scan().isEmpty)
    }

    func testIgnoresConductorOwnedTranscripts() throws {
        // A Conductor workspace transcript also lives in ~/.claude/projects —
        // the terminal scanner must not claim it (Conductor's scanner does).
        let conductorCwd = root.appendingPathComponent("conductor/workspaces/MyApp/new-york")
        try FileManager.default.createDirectory(at: conductorCwd, withIntermediateDirectories: true)
        try seed(uuid: "u4", lines: [userLine(), errorAssistant()], cwd: conductorCwd.path)
        XCTAssertTrue(scan().isEmpty)
    }

    func testDedupesToOnePerWorkspace() throws {
        // Several stalled transcripts in the same cwd → one entry, not many.
        try seed(uuid: "w1", lines: [userLine(), errorAssistant()])
        try seed(uuid: "w2", lines: [userLine(), errorAssistant()])
        try seed(uuid: "w3", lines: [userLine(), errorAssistant()])
        XCTAssertEqual(scan().count, 1)
    }

    /// Regression: a newer ACTIVE transcript in a cwd must not hide an older,
    /// still-stalled transcript there. The scanner keeps the newest STALLED
    /// transcript per dir, not merely the newest.
    func testOlderStalledFoundWhenNewestIsActive() throws {
        try seed(uuid: "old-stalled", lines: [userLine(), errorAssistant()])
        try seed(uuid: "new-active", lines: [userLine(), okAssistant()])
        let proj = projects.appendingPathComponent(workspace.resolvingSymlinksInPath().path
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression))
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3600)],
            ofItemAtPath: proj.appendingPathComponent("\(id("old-stalled")).jsonl").path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-600)],  // newest
            ofItemAtPath: proj.appendingPathComponent("\(id("new-active")).jsonl").path)

        let stalled = scan()
        XCTAssertEqual(stalled.count, 1)
        XCTAssertEqual(stalled.first?.claudeSessionID, id("old-stalled"))
    }

    private func errorAssistantAt(_ ts: String) -> String {
        #"{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"message":{"role":"assistant","content":[{"type":"text","text":"You've hit your usage limit"}]},"timestamp":"\#(ts)"}"#
    }

    // Fail closed: an undateable stall timestamp must not be treated as fresh.
    // It used to default to "now", which would resurrect a long-abandoned
    // session and burn the token budget.
    func testUndateableStallIsIgnored() throws {
        try seed(uuid: "bad-ts", lines: [userLine(), errorAssistantAt("not-a-timestamp")])
        XCTAssertTrue(scan().isEmpty)
    }

    // Security audit H2: a planted transcript claiming cwd = $HOME (or a
    // folder it wasn't filed under) must never become a resumable session.
    func testPlantedTranscriptPointingAtHomeIsIgnored() throws {
        try seed(uuid: "home", lines: [userLine(), errorAssistant()],
                 cwd: root.resolvingSymlinksInPath().path)
        XCTAssertTrue(scan().isEmpty)
    }

    func testTranscriptWithNonUUIDNameIsIgnored() throws {
        let dir = workspace.resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let proj = projects.appendingPathComponent(
            dir.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression))
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let body = [userLine(), errorAssistant()].joined(separator: "\n")
            .replacingOccurrences(of: "__CWD__", with: dir)
        try body.write(to: proj.appendingPathComponent("--dangerously-skip-permissions.jsonl"),
                       atomically: true, encoding: .utf8)
        XCTAssertTrue(scan().isEmpty)
    }

    // A genuinely old stall (beyond the 48h window) is ignored.
    func testOldStallBeyondWindowIgnored() throws {
        try seed(uuid: "old", lines: [userLine(), errorAssistantAt("2026-06-10T10:00:00.000Z")])
        XCTAssertTrue(scan().isEmpty)
    }
}
