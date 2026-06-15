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

    static func postMorningSummary(count: Int, sampleTitle: String?) {
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "🌙 Good morning"
        content.body = count == 1
            ? "Resumed 1 session while you slept\(sampleTitle.map { ": \($0)" } ?? ".")"
            : "Resumed \(count) sessions while you slept. Check your workspaces."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "night-conductor.morning",
            content: content,
            trigger: nil // deliver now
        )
        UNUserNotificationCenter.current().add(request)
    }
}
