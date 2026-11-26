import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac available for a reset in two complementary ways:
///   1. A power assertion that prevents idle sleep around a reset that stalled
///      work is waiting for (no privileges needed).
///   2. An optional weekly firmware wake a few minutes before Claude's reset
///      (`pmset repeat`, needs an admin prompt once) for a Mac that's asleep.
enum PowerManager {
    // MARK: - Prevent idle sleep (no privileges)

    private static var assertionID: IOPMAssertionID = 0
    private static var held = false

    /// Whether the keep-awake assertion is held right now, so the UI can show
    /// live proof ("Keeping your Mac awake") instead of an unverifiable claim.
    static var isHoldingAwake: Bool { held }

    /// Hold/release an assertion that stops the system idle-sleeping, so
    /// every overnight tick and resume actually runs. Idempotent.
    static func preventIdleSleep(_ on: Bool) {
        if on, !held {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Night Conductor is resuming sessions" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                held = true
            }
        } else if !on, held {
            IOPMAssertionRelease(assertionID)
            held = false
        }
    }

    // MARK: - Firmware wake schedule (needs admin prompt)

    /// Schedule a weekly wake-or-power-on just before the reset (see
    /// `ResetWatch.wakeSpec`). `pmset` keeps one repeating schedule, so this
    /// replaces any earlier one. Shows the native admin prompt once. The spec
    /// is built from a fixed letter set and a formatted time, never free text.
    @discardableResult
    static func scheduleResetWake(_ spec: ResetWatch.WakeSpec) -> Bool {
        guard "MTWRFSU".contains(spec.day), spec.day.count == 1,
              spec.time.range(of: #"^\d{2}:\d{2}:00$"#, options: .regularExpression) != nil
        else { return false }
        guard runPrivileged("/usr/bin/pmset repeat \(spec.pmsetArguments)") else { return false }
        if let data = try? JSONEncoder().encode(spec) {
            UserDefaults.standard.set(data, forKey: scheduledSpecKey)
        }
        return true
    }

    @discardableResult
    static func cancelScheduledWake() -> Bool {
        guard runPrivileged("/usr/bin/pmset repeat cancel") else { return false }
        UserDefaults.standard.removeObject(forKey: scheduledSpecKey)
        return true
    }

    private static let scheduledSpecKey = "resetWakeSpec"

    /// What we last asked pmset for, to tell "scheduled for this reset" from
    /// "scheduled for an old one" (a free reset moves the week).
    static var scheduledSpec: ResetWatch.WakeSpec? {
        guard let data = UserDefaults.standard.data(forKey: scheduledSpecKey) else { return nil }
        return try? JSONDecoder().decode(ResetWatch.WakeSpec.self, from: data)
    }

    /// The Mac's current repeating power events (`pmset -g sched`), one line
    /// each. Read-only, no privileges. `pmset repeat` replaces the whole
    /// repeating schedule, so settings shows these before overwriting them.
    static func repeatingEvents() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "sched"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseRepeating(String(decoding: data, as: UTF8.self))
    }

    /// Lines under "Repeating power events:" up to the next section.
    static func parseRepeating(_ output: String) -> [String] {
        var inSection = false
        var events: [String] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("repeating power events") { inSection = true; continue }
            if inSection {
                if line.isEmpty || line.hasSuffix(":") { break }
                events.append(String(line.prefix(120)))
            }
        }
        return events
    }

    private static func runPrivileged(_ command: String) -> Bool {
        // `with administrator privileges` shows the native auth dialog once.
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0 // non-zero if the user cancels
    }
}
