import AppKit
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

/// Notification permission for budget alerts, asked from the setup checklist
/// (at a calm moment, with the reason shown) rather than mid-alarm.
enum NotificationPermission {
    static func isAllowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// Ask if macOS hasn't asked yet; if the user said no before, macOS won't
    /// ask again, so open the Notifications settings instead.
    static func requestOrOpenSettings() async {
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
