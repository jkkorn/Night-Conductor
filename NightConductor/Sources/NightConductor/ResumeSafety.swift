import Foundation

/// Guards on the one dangerous thing this app does: start an unattended
/// `claude` agent (edits auto-accepted) using a session id and a working
/// directory read from files OTHER programs wrote. Trust follows who wrote a
/// value, not which channel delivered it, so both are validated here at the
/// sink as well as at parse time.
enum ResumeSafety {
    private static let uuid = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")

    /// Claude session ids are UUIDs. Anything else, notably a value starting
    /// with "-", could be parsed by `claude` as a flag (argument injection).
    static func isValidSessionID(_ id: String) -> Bool {
        uuid.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    /// A project folder: absolute, inside the home folder (symlinks and ".."
    /// resolved), strictly below it, outside ~/Library, and with no hidden
    /// component (.ssh, .git/hooks, .config…). Never `$HOME` itself, so a
    /// crafted row can't point an auto-accepting agent at your dotfiles.
    static func isSafeWorkspace(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let base = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(base + "/") else { return false }
        let below = resolved.dropFirst(base.count + 1).split(separator: "/")
        guard let first = below.first, first != "Library" else { return false }
        return !below.contains { $0.hasPrefix(".") }
    }

    /// Claude Code files each transcript under its cwd with every
    /// non-alphanumeric character replaced by "-". A transcript whose claimed
    /// cwd doesn't encode to its own folder was not written there by Claude.
    static func cwdMatchesProjectDir(_ cwd: String, projectDir: String) -> Bool {
        cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression) == projectDir
    }

    /// Whether a session title is specific enough to find that one session by
    /// its label in another app. "Untitled", empty and very short titles
    /// match too many things, so automation must not click on them.
    static func isDistinctiveTitle(_ title: String) -> Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = ["untitled", "new chat", "new session", "new conversation"]
        return t.count >= 6 && !generic.contains(t)
    }

    /// A single file name another app wrote that we'll use to build a path:
    /// letters, digits, "-" and "_" only, so "../" can't walk out.
    static func isSafePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Both checks a resume must pass before any process is started.
    static func allowsHeadlessResume(_ session: StalledSession) -> Bool {
        isValidSessionID(session.claudeSessionID) && isSafeWorkspace(session.workspacePath)
    }
}
