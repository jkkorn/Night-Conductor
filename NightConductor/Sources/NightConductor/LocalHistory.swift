import Foundation

/// Everything Night Conductor remembers about past resumes, in one place, so
/// people can wipe it: resumed session titles, the keep-awake and power logs,
/// and the usage samples behind the burn-rate forecast. Settings and
/// credentials are not touched.
enum LocalHistory {
    static let defaultsKeys = ["resumeHistory", "holdLog", "powerLog",
                               "summaryTitle", "summaryCount", "summaryBackground",
                               // left behind by the old night-watch versions
                               "nightCounts", "nightFailures", "nightKey", "pinnedSessions",
                               "lastSummaryNight"]

    static func clearAll(defaults: UserDefaults = .standard,
                         samplesURL: URL = UsageSampleLog.defaultURL,
                         fileManager: FileManager = .default) {
        defaultsKeys.forEach(defaults.removeObject(forKey:))
        // A fixed file inside our own Application Support folder, never a
        // path read from elsewhere.
        if SafeFile.isRegularNonSymlink(samplesURL) {
            try? fileManager.removeItem(at: samplesURL)
        }
    }
}
