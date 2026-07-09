import Foundation

/// Drives the first-run "Finish setup" card. Most setup is automatic now
/// (armed and launch-at-login default on, usage reads itself), so the card
/// exists for the one genuinely manual step: granting Accessibility, without
/// which resumes still run but only in the background instead of inside
/// Conductor. It shows until that is granted, unless the user dismisses it,
/// and never during an offscreen documentation render.
enum SetupStatus {
    static func shouldShow(accessibilityGranted: Bool, dismissed: Bool,
                           isScreenshot: Bool, hasBlockedSessions: Bool = false) -> Bool {
        if isScreenshot || accessibilityGranted { return false }
        // Dismissal is respected until a session is ACTUALLY blocked on the
        // missing permission, then re-raise: "I can't act" must not be
        // dismissable into silence. This closes the permanent-dismissal hole,
        // where an unsigned reinstall drops Accessibility but the card, once
        // dismissed, never came back.
        return !dismissed || hasBlockedSessions
    }
}
