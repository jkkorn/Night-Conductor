import Foundation

/// Drives the first-run "Finish setup" card. Most setup is automatic now
/// (armed and launch-at-login default on, usage reads itself), so the card
/// exists for the one genuinely manual step: granting Accessibility, without
/// which resumes still run but only in the background instead of inside
/// Conductor. It shows until that is granted, unless the user dismisses it,
/// and never during an offscreen documentation render.
enum SetupStatus {
    static func shouldShow(accessibilityGranted: Bool, dismissed: Bool, isScreenshot: Bool) -> Bool {
        !isScreenshot && !dismissed && !accessibilityGranted
    }
}
