import AppKit
import Foundation
import UserNotifications

/// Two kinds of good news, each sent once: stalled work resumed after a
/// reset, and a week that just reset. Permission is requested when the user
/// turns auto-resume on or from the setup card, never as a launch prompt.
enum Notifications {
    static func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// After a run of unattended resumes finishes (nothing left waiting).
    static func postResumeSummary(count: Int, sampleTitle: String?, backgroundCount: Int = 0) {
        guard count > 0 else { return }
        let lead = count == 1
            ? "Resumed 1 stalled session\(sampleTitle.map { ": \($0)" } ?? ".")"
            : "Resumed \(count) stalled sessions."
        // A headless (background) resume lands work in your workspace but never
        // updates the host app's chat, so point the user at their diffs.
        let whereToLook = backgroundCount > 0
            ? " Some ran in the background: check your workspace diffs, not the chat."
            : ""
        post(id: "night-conductor.resumed", title: "Back to work", body: lead + whereToLook)
    }

    /// "Claude's week reset. You're back to 0% used."
    static func postWeekReset(provider: ProviderID, next: Date?) {
        let nextText = next.map { " Next reset \($0.formatted(.dateTime.weekday(.wide).hour().minute()))." } ?? ""
        post(id: "night-conductor.reset.\(provider.rawValue)",
             title: "\(provider.displayName)\u{2019}s week reset",
             body: "Your weekly allowance is fresh again.\(nextText)")
    }

    private static func post(id: String, title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Notification permission for budget alerts, asked from the setup checklist
/// (at a calm moment, with the reason shown) rather than mid-alarm.
enum NotificationPermission {
    static func isAllowed() async -> Bool {
        // Outside an app bundle (tests, offscreen renders) macOS throws on
        // UNUserNotificationCenter.current(); there's nothing to ask there.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return true }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// Ask if macOS hasn't asked yet; if the user said no before, macOS won't
    /// ask again, so open the Notifications settings instead.
    static func requestOrOpenSettings() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        default:
            await MainActor.run {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
