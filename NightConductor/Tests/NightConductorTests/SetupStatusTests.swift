import XCTest

@testable import NightConductor

final class SetupStatusTests: XCTestCase {
    func testShowsUntilAccessibilityGrantedOrDismissed() {
        // Fresh install: not granted, not dismissed → show the card.
        XCTAssertTrue(SetupStatus.shouldShow(
            accessibilityGranted: false, dismissed: false, isScreenshot: false))
        // Accessibility granted → setup is effectively done, hide it.
        XCTAssertFalse(SetupStatus.shouldShow(
            accessibilityGranted: true, dismissed: false, isScreenshot: false))
        // User dismissed it → stay hidden even while pending.
        XCTAssertFalse(SetupStatus.shouldShow(
            accessibilityGranted: false, dismissed: true, isScreenshot: false))
        // Offscreen documentation render never shows onboarding.
        XCTAssertFalse(SetupStatus.shouldShow(
            accessibilityGranted: false, dismissed: false, isScreenshot: true))
    }

    // A session actually blocked on the missing permission re-raises the card
    // even after the user dismissed it (the permanent-dismissal hole). "I can't
    // act" must not be dismissable into silence.
    func testBlockedSessionReRaisesThroughDismissal() {
        XCTAssertTrue(SetupStatus.shouldShow(
            accessibilityGranted: false, dismissed: true, isScreenshot: false, hasBlockedSessions: true))
        // Dismissed and nothing blocked: stay hidden, respect the dismissal.
        XCTAssertFalse(SetupStatus.shouldShow(
            accessibilityGranted: false, dismissed: true, isScreenshot: false, hasBlockedSessions: false))
        // Granted or screenshot still win over a block.
        XCTAssertFalse(SetupStatus.shouldShow(
            accessibilityGranted: true, dismissed: false, isScreenshot: false, hasBlockedSessions: true))
        XCTAssertFalse(SetupStatus.shouldShow(
            accessibilityGranted: false, dismissed: false, isScreenshot: true, hasBlockedSessions: true))
    }
}
