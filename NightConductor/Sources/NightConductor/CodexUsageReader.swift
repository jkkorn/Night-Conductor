import Foundation

/// ChatGPT's Codex limits, read from the Codex CLI's own session logs.
///
/// Every Codex turn appends a `token_count` event carrying the live
/// `rate_limits` the server returned (the same numbers Codex's `/status`
/// shows). Reading them from disk needs no credential and no network call.
/// Untrusted input: we only take numbers out of these files, clamp them, and
/// never let them influence a path, an argument or a resume.
enum CodexUsageReader {
    static let tailBytes = 256 * 1024          // a turn's rate_limits is always near the end
    static let maxFileAge: TimeInterval = 8 * 86_400

    static var defaultSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: defaultSessionsDir.path)
    }

    /// The newest reading across recent session logs, or nil.
    static func read(sessionsDir: URL = defaultSessionsDir, now: Date = Date()) -> ProviderUsage? {
        guard let newest = newestLog(in: sessionsDir, now: now) else { return nil }
        return SafeFile.readTail(newest, maxBytes: tailBytes).flatMap(latestUsage(inTail:))
    }

    /// Newest `.jsonl` by modification time, skipping symlinks and anything
    /// that resolves outside `root`, and files older than `maxFileAge`.
    static func newestLog(in root: URL, now: Date) -> URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        var best: (url: URL, date: Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) <= maxFileAge,
                  SafeFile.isInside(url, root: root)
            else { continue }
            if best.map({ modified > $0.date }) ?? true { best = (url, modified) }
        }
        return best?.url
    }

    /// Scan a log tail from the end for the last line carrying rate limits.
    static func latestUsage(inTail data: Data) -> ProviderUsage? {
        // Lossy decode: a tail can start mid-codepoint; only the first
        // (partial) line is affected and it's skipped by the JSON parse.
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let usage = parseLine(String(line)) { return usage }
        }
        return nil
    }

    static func parseLine(_ line: String) -> ProviderUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "token_count",
              let limits = payload["rate_limits"] as? [String: Any]
        else { return nil }
        // Pick the longest window as "weekly" (today that's the only one).
        let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
        guard let weekly = windows.max(by: { minutes($0) < minutes($1) }),
              let used = (weekly["used_percent"] as? NSNumber)?.doubleValue
        else { return nil }
        let readAt = SafeFile.plausibleReadAt((object["timestamp"] as? String).flatMap(ISO.parse))
        // Judged against when the reading was taken: an old log's reset may
        // already be past, but never decades off.
        let resets = SafeFile.plausibleReset(
            (weekly["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            now: readAt)
        let plan = (limits["plan_type"] as? String).map { $0.prefix(24).capitalized }
        return ProviderUsage(
            provider: .chatgpt, source: "Codex", plan: plan,
            weekly: UsageWindow(utilization: SafeFile.clampPercent(used), resetsAt: resets),
            windowLength: minutes(weekly) > 0 ? minutes(weekly) * 60 : ProviderUsage.week,
            readAt: readAt
        )
    }

    /// Window length in minutes, bounded to 1 minute to 31 days.
    private static func minutes(_ window: [String: Any]) -> Double {
        let raw = (window["window_minutes"] as? NSNumber)?.doubleValue ?? 0
        return raw.isFinite ? min(max(raw, 0), 31 * 24 * 60) : 0
    }
}
