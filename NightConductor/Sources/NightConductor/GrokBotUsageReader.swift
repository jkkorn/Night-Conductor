import Foundation

/// Grok Bot's weekly allowance, read from the reading the app itself caches.
///
/// Grok Bot persists small JSON "slices" under `sand-client-persistence/`,
/// each named by the base32 of its key. The one ending `.weekly-usage.cache`
/// holds the last weekly reading it fetched. We decode filenames to find it
/// and read only that file: never `sand-secrets.json`, cookies or anything
/// outside the directory.
enum GrokBotUsageReader {
    static let maxBlobBytes = 64 * 1024
    static let cacheSuffix = ".weekly-usage.cache"

    static var defaultDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Grok Bot.app")
            || FileManager.default.fileExists(atPath: defaultDir.path)
    }

    static func read(dir: URL = defaultDir) -> ProviderUsage? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        // Several accounts can be signed in over time; take the freshest reading.
        return names
            .filter { decodeBlobName($0)?.hasSuffix(cacheSuffix) == true }
            .compactMap { name -> ProviderUsage? in
                let url = dir.appendingPathComponent(name)
                guard SafeFile.isRegularNonSymlink(url), SafeFile.isInside(url, root: dir) else { return nil }
                return SafeFile.readAll(url, maxBytes: maxBlobBytes).flatMap(parse)
            }
            .max { $0.readAt < $1.readAt }
    }

    /// Accepts only `<base32>.blob` (RFC 4648 alphabet, lowercase, unpadded).
    static func decodeBlobName(_ filename: String) -> String? {
        guard filename.hasSuffix(".blob") else { return nil }
        let encoded = filename.dropLast(5).uppercased()
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for ch in encoded {
            guard let index = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func parse(_ data: Data) -> ProviderUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["value"] as? [String: Any],
              (value["kind"] as? String) == "present",
              let reading = value["reading"] as? [String: Any],
              let usage = reading["usage"] as? [String: Any],
              let percent = (usage["percentUsed"] as? NSNumber)?.doubleValue
        else { return nil }
        let resets = (usage["nextResetMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let readAt = (reading["readAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let plan = (usage["grokPlanLabel"] as? String).map { String($0.prefix(32)) }
        return ProviderUsage(
            provider: .grok, source: "Grok Bot", plan: plan,
            weekly: UsageWindow(utilization: SafeFile.clampPercent(percent), resetsAt: resets),
            readAt: readAt ?? Date()
        )
    }
}
