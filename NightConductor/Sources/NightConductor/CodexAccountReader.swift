import Foundation

/// ChatGPT's weekly allowance, read from the account itself by asking the
/// official Codex program (`codex app-server`, the same channel the ChatGPT
/// app and Conductor use) for `account/rateLimits/read`.
///
/// Why not just Codex's log files: those only exist for runs on THIS Mac.
/// Runs in the cloud (Conductor Build, Codex web) spend the same allowance
/// but leave nothing here, so the logs can say "reset, nothing since" while
/// the week is half gone. The account knows the truth.
///
/// We never touch the ChatGPT sign-in ourselves: Codex uses its own login.
enum CodexAccountReader {
    /// Official Codex binaries, in order of preference. Fixed paths only:
    /// nothing from the environment decides what we launch.
    static var candidateBinaries: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Application Support/com.conductor.app/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
    }

    static let timeout: TimeInterval = 15
    static let maxOutputBytes = 1_048_576

    /// A fresh reading, or nil if no Codex is installed, it isn't signed in,
    /// or it didn't answer in time. Blocking: call off the main thread.
    static func read(now: Date = Date()) -> ProviderUsage? {
        guard let binary = candidateBinaries.first(where: FileManager.default.isExecutableFile(atPath:)),
              let output = run(binary: binary)
        else { return nil }
        return parse(output, now: now)
    }

    /// At most one account check every 5 minutes (it starts a process and
    /// makes a network call). A good reading is reused for up to 30 minutes
    /// if a later check fails, then we fall back to the local logs.
    static let minInterval: TimeInterval = 300
    static let maxReuse: TimeInterval = 1800
    private static let cache = ReadingCache()

    static func cachedRead(now: Date = Date()) -> ProviderUsage? {
        if cache.attemptedRecently(now: now, within: minInterval) {
            return cache.reusable(now: now, within: maxReuse)
        }
        cache.markAttempt(now)
        if let fresh = read(now: now) {
            cache.store(fresh)
            return fresh
        }
        return cache.reusable(now: now, within: maxReuse)
    }

    // MARK: - Process

    private static func run(binary: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let collected = OutputCollector()
        let answered = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty || collected.append(chunk, limit: maxOutputBytes) { answered.signal() }
        }
        do { try process.run() } catch { return nil }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"night-conductor","version":"1"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(requests.utf8))

        let finished = answered.wait(timeout: .now() + timeout) == .success
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        return finished || collected.hasAnswer ? collected.data : nil
    }

    // MARK: - Parsing

    /// Finds the reply to request 2 among the JSON lines and reads the
    /// longest window as "this week". Every value is untrusted and bounded.
    static func parse(_ data: Data, now: Date) -> ProviderUsage? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 2,
                  let result = object["result"] as? [String: Any],
                  let limits = result["rateLimits"] as? [String: Any]
            else { continue }
            let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
            guard let weekly = windows.max(by: { minutes($0) < minutes($1) }),
                  let used = (weekly["usedPercent"] as? NSNumber)?.doubleValue
            else { return nil }
            let resets = SafeFile.plausibleReset(
                (weekly["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }, now: now)
            let plan = (limits["planType"] as? String).map { String($0.prefix(24)).capitalized }
            let credits = (result["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? NSNumber
            var usage = ProviderUsage(
                provider: .chatgpt, source: "ChatGPT account", plan: plan,
                weekly: UsageWindow(utilization: SafeFile.clampPercent(used), resetsAt: resets),
                windowLength: minutes(weekly) > 0 ? minutes(weekly) * 60 : ProviderUsage.week,
                readAt: now
            )
            usage.freeResetsAvailable = min(max(credits?.intValue ?? 0, 0), 99)
            return usage
        }
        return nil
    }

    private static func minutes(_ window: [String: Any]) -> Double {
        let raw = (window["windowDurationMins"] as? NSNumber)?.doubleValue ?? 0
        return raw.isFinite ? min(max(raw, 0), 31 * 24 * 60) : 0
    }
}

/// Thread-safe buffer for the app-server's output; reports once the reply
/// we asked for has arrived (or the cap is hit) so we can stop waiting.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var hasAnswer = false

    var data: Data { lock.withLock { buffer } }

    /// Returns true when it's time to stop reading.
    func append(_ chunk: Data, limit: Int) -> Bool {
        lock.withLock {
            buffer.append(chunk)
            hasAnswer = hasAnswer || buffer.range(of: Data(#""id":2"#.utf8)) != nil
                && buffer.last == UInt8(ascii: "\n")
            return hasAnswer || buffer.count >= limit
        }
    }
}

private final class ReadingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAttempt: Date?
    private var lastGood: ProviderUsage?

    func attemptedRecently(now: Date, within interval: TimeInterval) -> Bool {
        lock.withLock { lastAttempt.map { now.timeIntervalSince($0) < interval } ?? false }
    }

    func markAttempt(_ now: Date) { lock.withLock { lastAttempt = now } }
    func store(_ usage: ProviderUsage) { lock.withLock { lastGood = usage } }

    func reusable(now: Date, within interval: TimeInterval) -> ProviderUsage? {
        lock.withLock { lastGood.flatMap { now.timeIntervalSince($0.readAt) < interval ? $0 : nil } }
    }
}

