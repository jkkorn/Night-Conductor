import XCTest

@testable import NightConductor

/// Regression tests for the security-and-hardening pass: each one pins a
/// finding so it can't quietly come back.
final class SecurityHardeningTests: XCTestCase {
    // MARK: M2: automation only clicks on titles that identify one session

    func testGenericAndShortTitlesAreNotDistinctive() {
        XCTAssertFalse(ResumeSafety.isDistinctiveTitle("Untitled"))
        XCTAssertFalse(ResumeSafety.isDistinctiveTitle("  untitled "))
        XCTAssertFalse(ResumeSafety.isDistinctiveTitle("New chat"))
        XCTAssertFalse(ResumeSafety.isDistinctiveTitle("fix"))
        XCTAssertFalse(ResumeSafety.isDistinctiveTitle(""))
        XCTAssertTrue(ResumeSafety.isDistinctiveTitle("Refactor onboarding flow"))
    }

    // MARK: L1: a session id from JSON can't walk out of its folder

    func testPathComponentRejectsTraversal() {
        XCTAssertTrue(ResumeSafety.isSafePathComponent("local_3f2a-91bc"))
        XCTAssertFalse(ResumeSafety.isSafePathComponent("../../.ssh"))
        XCTAssertFalse(ResumeSafety.isSafePathComponent("a/b"))
        XCTAssertFalse(ResumeSafety.isSafePathComponent(""))
        XCTAssertFalse(ResumeSafety.isSafePathComponent(String(repeating: "a", count: 200)))
    }

    // MARK: L2: absurd numbers from other apps can't crash the app

    func testAbsurdResetIsDropped() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(SafeFile.plausibleReset(Date(timeIntervalSince1970: 1e300), now: now))
        XCTAssertNil(SafeFile.plausibleReset(now.addingTimeInterval(-3 * 86_400), now: now))
        let soon = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(SafeFile.plausibleReset(soon, now: now), soon)
    }

    func testFutureReadTimeIsClampedToNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SafeFile.plausibleReadAt(now.addingTimeInterval(86_400 * 365), now: now), now)
        XCTAssertEqual(SafeFile.plausibleReadAt(nil, now: now), now)
    }

    func testCodexLineWithAbsurdResetParsesWithoutReset() {
        let line = #"{"timestamp":"2026-11-20T10:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40,"window_minutes":1e300,"resets_at":1e300}}}}"#
        let usage = CodexUsageReader.parseLine(line)
        XCTAssertNotNil(usage)
        XCTAssertNil(usage?.weekly.resetsAt)
        XCTAssertEqual(usage?.weekly.utilization, 40)
    }

    // MARK: L5: only usage and rate limits count as a stall

    func testContextLimitIsNotAUsageStall() {
        XCTAssertFalse(ClaudeCodeDB.isUsageLimitText("Prompt is too long: context limit exceeded"))
        XCTAssertFalse(ClaudeCodeDB.isUsageLimitText("limit"))
        XCTAssertTrue(ClaudeCodeDB.isUsageLimitText("Claude usage limit reached. Your limit will reset at 5pm"))
        XCTAssertTrue(ClaudeCodeDB.isUsageLimitText("API Error: Rate limit exceeded"))
    }

    // MARK: M1: a pressed Retry never also starts a headless agent

    func testUnconfirmedRetryIsMarkedPressed() {
        XCTAssertFalse(ResumeResult(ok: false, detail: "not found").pressed)
        XCTAssertTrue(ResumeResult(ok: false, detail: "pressed", pressed: true).pressed)
    }

    // MARK: L4: keep only what's needed, and let people delete it

    func testHistoryKeepsOnlyTheStartOfATitle() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nc.tests.history.\(UUID())"))
        let long = String(repeating: "secret prompt text ", count: 20)
        ResumeHistory.record(ResumeEvent(date: Date(), title: long, kind: "usage_limit", inConductor: true),
                             defaults: defaults)
        XCTAssertEqual(ResumeHistory.load(defaults: defaults).first?.title.count, ResumeHistory.maxTitleLength)
    }

    func testClearAllRemovesHistoryAndSamples() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nc.tests.clear.\(UUID())"))
        LocalHistory.defaultsKeys.forEach { defaults.set(Data([1]), forKey: $0) }
        let samples = FileManager.default.temporaryDirectory.appendingPathComponent("samples-\(UUID()).json")
        try Data("[]".utf8).write(to: samples)

        LocalHistory.clearAll(defaults: defaults, samplesURL: samples)

        LocalHistory.defaultsKeys.forEach { XCTAssertNil(defaults.object(forKey: $0)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: samples.path))
    }
}
