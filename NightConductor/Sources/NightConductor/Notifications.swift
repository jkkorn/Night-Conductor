import Foundation
import UserNotifications

/// Morning summary: a single notification when the watch window ends, if
/// anything was resumed overnight. Permission is requested only when the
/// user first arms the watch — never an unsolicited launch prompt.
enum Notifications {
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func postMorningSummary(count: Int, sampleTitle: String?, backgroundCount: Int = 0) {
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "🌙 Good morning"
        let lead = count == 1
            ? "Resumed 1 session while you slept\(sampleTitle.map { ": \($0)" } ?? ".")"
            : "Resumed \(count) sessions while you slept."
        // A headless (background) resume lands work in your workspace but never
        // updates the host app's chat, so point the user at their diffs. This is
        // the exact mismatch that makes a working night look like a broken one.
        let whereToLook = backgroundCount > 0
            ? " Check your workspace diffs, not the chat. Some ran in the background."
            : (count == 1 ? "" : " Check your workspaces.")
        content.body = lead + whereToLook
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "night-conductor.morning",
            content: content,
            trigger: nil // deliver now
        )
        UNUserNotificationCenter.current().add(request)
    }
}
