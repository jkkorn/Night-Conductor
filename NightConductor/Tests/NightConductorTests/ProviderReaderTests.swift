import XCTest

@testable import NightConductor

final class ProviderReaderTests: XCTestCase {
    // MARK: Claude: the 5-hour window is gone (API now sends `five_hour: null`)

    func testClaudeNullFiveHourParsesAsNoWindow() {
        XCTAssertNil(UsageClient.parseOptionalWindow(NSNull()))
        XCTAssertNil(UsageClient.parseOptionalWindow(nil))
        let w = UsageClient.parseOptionalWindow(["utilization": 40, "resets_at": "2026-11-20T04:59:59.619336+00:00"])
        XCTAssertEqual(w?.utilization, 40)
    }

    func testClaudeWindowStartFromBreakdown() {
        let start = UsageClient.parseWindowStart([
            "as_of": "2026-11-15T20:09:33.657082+00:00",
            "window_started_at": "2026-11-13T04:59:59.619336+00:00",
        ])
        XCTAssertEqual(start, ISO.parse("2026-11-13T04:59:59Z"))
    }

    func testClaudeProviderFromSnapshot() {
        let reset = Date(timeIntervalSince1970: 1_795_000_000)
        let snap = UsageSnapshot(fiveHour: nil,
                                 sevenDay: UsageWindow(utilization: 11, resetsAt: reset),
                                 fetchedAt: Date(timeIntervalSince1970: 1_794_700_000))
        let p = ProviderUsage.claude(from: snap)
        XCTAssertEqual(p.provider, .claude)
        XCTAssertEqual(p.weekly.utilization, 11)
        XCTAssertEqual(p.windowStart, reset.addingTimeInterval(-7 * 86_400))
    }

    // MARK: ChatGPT via Codex session logs

    private let codexLine = #"""
    {"timestamp":"2026-11-15T20:13:19.551Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":24.0,"window_minutes":10080,"resets_at":1795210269},"secondary":null,"plan_type":"pro"}}}
    """#

    func testCodexParsesWeeklyPrimary() throws {
        let u = try XCTUnwrap(CodexUsageReader.parseLine(codexLine))
        XCTAssertEqual(u.provider, .chatgpt)
        XCTAssertEqual(u.weekly.utilization, 24)
        XCTAssertEqual(u.weekly.resetsAt, Date(timeIntervalSince1970: 1_795_210_269))
        XCTAssertEqual(u.windowLength, 10080 * 60)
        XCTAssertEqual(u.plan, "Pro")
        XCTAssertEqual(u.readAt, ISO.parse("2026-11-15T20:13:19Z"))
    }

    func testCodexPicksLongestWindowWhenBothPresent() throws {
        let line = #"{"timestamp":"2026-11-15T20:13:19Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":70,"window_minutes":300,"resets_at":1795000000},"secondary":{"used_percent":30,"window_minutes":10080,"resets_at":1795210269}}}}"#
        let u = try XCTUnwrap(CodexUsageReader.parseLine(line))
        XCTAssertEqual(u.weekly.utilization, 30)
    }

    func testCodexIgnoresOtherLinesAndGarbage() {
        XCTAssertNil(CodexUsageReader.parseLine(#"{"type":"response_item","payload":{"type":"message"}}"#))
        XCTAssertNil(CodexUsageReader.parseLine("not json"))
        XCTAssertNil(CodexUsageReader.parseLine(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#))
    }

    func testCodexTailScanTakesLastReading() throws {
        let older = codexLine.replacingOccurrences(of: "24.0", with: "20.0")
        let tail = Data((older + "\n" + #"{"type":"response_item"}"# + "\n" + codexLine + "\n").utf8)
        XCTAssertEqual(CodexUsageReader.latestUsage(inTail: tail)?.weekly.utilization, 24)
    }

    func testCodexReadsNewestFileInDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString)/2026/11/15", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("rollout-a.jsonl")
        let new = dir.appendingPathComponent("rollout-b.jsonl")
        try Data((codexLine.replacingOccurrences(of: "24.0", with: "5.0") + "\n").utf8).write(to: old)
        try Data((codexLine + "\n").utf8).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        let root = dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(CodexUsageReader.read(sessionsDir: root)?.weekly.utilization, 24)
    }

    // MARK: Grok Bot cached weekly reading

    func testBase32FilenameDecodes() {
        // "sand.client.slice.ui-layout"
        XCTAssertEqual(GrokBotUsageReader.decodeBlobName("onqw4zbomnwgszlooqxhg3djmnss45ljfvwgc6lpov2a.blob"),
                       "sand.client.slice.ui-layout")
        XCTAssertNil(GrokBotUsageReader.decodeBlobName("not-base32!.blob"))
    }

    func testGrokParsesWeeklyCache() throws {
        let json = #"{"schemaVersion":2,"value":{"kind":"present","reading":{"usage":{"percentUsed":51.943229,"nextResetMs":1794933570569,"grokPlanLabel":"Grok Bot Plan"},"readAtMs":1794604970820}}}"#
        let u = try XCTUnwrap(GrokBotUsageReader.parse(Data(json.utf8)))
        XCTAssertEqual(u.provider, .grok)
        XCTAssertEqual(u.weekly.utilization, 51.943229, accuracy: 0.0001)
        XCTAssertEqual(u.weekly.resetsAt, Date(timeIntervalSince1970: 1_794_933_570.569))
        XCTAssertEqual(u.readAt, Date(timeIntervalSince1970: 1_794_604_970.820))
        XCTAssertEqual(u.plan, "Grok Bot Plan")
    }

    func testGrokRejectsAbsentReading() {
        XCTAssertNil(GrokBotUsageReader.parse(Data(#"{"schemaVersion":2,"value":{"kind":"absent"}}"#.utf8)))
        XCTAssertNil(GrokBotUsageReader.parse(Data("garbage".utf8)))
    }

    // MARK: Readings from an already-reset window

    func testReadingFromExpiredWindowShowsAsReset() {
        let past = Date(timeIntervalSince1970: 1_000)
        let u = ProviderUsage(provider: .grok, source: "Grok Bot", plan: nil,
                              weekly: UsageWindow(utilization: 80, resetsAt: past),
                              readAt: past.addingTimeInterval(-60))
        let shown = u.normalized(now: past.addingTimeInterval(10))
        XCTAssertEqual(shown.weekly.utilization, 0)
        XCTAssertTrue(shown.isResetSinceReading)
    }
}
