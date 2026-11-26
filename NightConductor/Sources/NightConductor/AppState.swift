import Foundation
import SwiftUI

/// Orchestrates two independent loops:
///   • a fast **view loop** that refreshes the displayed usage and stalled
///     list every `scanInterval` (the local DB scan is essentially free, so
///     the list never shows sessions that already recovered), and
///   • a slower **resume loop** that, when auto-resume is on and the week has
///     room, resumes stalled sessions one at a time, re-checking after each.
/// There is no night window: a session stalled on a weekly limit can run
/// again the moment the week resets, at whatever hour that is.
@MainActor
final class AppState: ObservableObject {
    @Published var usage: UsageSnapshot?
    @Published var stalled: [StalledSession] = []
    @Published var decision: Decision?
    @Published var activity: [String] = []
    @Published var isWorking = false
    @Published var currentlyResuming: String?
    @Published var lastTick: Date?
    @Published var update: UpdateChecker.Release?   // set when a newer release exists
    // Every AI subscription we can read (Claude, ChatGPT via Codex, Grok Bot),
    // plus the forecast for each. Maintained in AppState+Budgets.swift.
    @Published var providers: [ProviderUsage] = []
    @Published var assessments: [ProviderID: BurnAssessment] = [:]
    @Published var otherAITools: [String] = []
    var lastLocalProviderRead: Date?
    var cachedLocalProviders: [ProviderUsage] = []
    lazy var sampleLog: UsageSampleLog = isScreenshot ? UsageSampleLog() : UsageSampleLog.load()

    static let scanInterval: TimeInterval = 30        // local DB scan — cheap
    static let resumeInterval: TimeInterval = 600     // how often resumes are attempted
    // The usage API rate-limits rapid polling (429 within seconds), so the
    // 30s view loop reads it from cache and only re-fetches this often.
    static let usageRefreshInterval: TimeInterval = 180   // 3 min
    static let usageStaleAfter: TimeInterval = 900        // 15 min → treat as unavailable
    static let maxAttemptsPerPass = 8                     // bound a pass when sessions fail
    nonisolated static let transientCooldown: TimeInterval = 300      // 5 min before retrying a server rate-limit
    nonisolated static let resumeCooldown: TimeInterval = 600         // 10 min before re-firing the SAME session
    static let minUsageAttemptGap: TimeInterval = 20      // floor between /usage calls, even forced ones

    private var viewLoop: Task<Void, Never>?
    private var resumeLoop: Task<Void, Never>?
    private var lastUsageFetchAt: Date?
    private var lastUsageAttemptAt: Date?  // every attempt (success or fail), to floor the rate
    private var usageBackoffUntil: Date?   // set on a 429, grows exponentially
    private var usageBackoffStep = 0
    private var usageJitter: Double = 0     // randomized offset so polls desync
    private var signInExpired = false       // Claude Code token expired → tell the user
    private var lastKeepAwake = false  // last computed keep-awake state, to log real transitions
    private var lastClaudeCodeScan: Date?
    private var cachedClaudeCode: [StalledSession] = []
    private var lastResumedAt: [String: Date] = [:]  // ledgerKey -> last resume, to space re-fires
    // Guards against the resume loop and the manual "Resume now" button
    // running a resume pass at the same time (which could double-run a
    // session and bypass the daily caps).
    private var isResuming = false
    let isScreenshot: Bool  // true → inert demo state; never hit the live API
    var screenshotSetup: String?  // demo-only: force the setup card in the design render

    init(forScreenshots: Bool = false) {
        isScreenshot = forScreenshots
        UserDefaults.standard.register(defaults: [
            "armed": true,
            "weeklyCeiling": 90.0,
        ])
        if forScreenshots { return } // inert state; data injected by caller
        usageJitter = Double(Int.random(in: 0...45)) // desync the very first poll too
        // No accessibility prompt at launch — that nags on every relaunch.
        // The settings panel shows a button to grant it on the user's terms.
        start()
    }

    var armed: Bool {
        get { UserDefaults.standard.bool(forKey: "armed") }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "armed")
            if newValue {
                Notifications.requestAuthorizationIfNeeded() // for the "resumed" note
            } else {
                PowerManager.preventIdleSleep(false) // let it sleep
            }
            log(newValue ? "Auto-resume on" : "Auto-resume paused")
        }
    }

    func start() {
        viewLoop?.cancel()
        resumeLoop?.cancel()
        // Reliability: default to launching at login (first launch only), so a
        // restart never leaves the watch silently dead. And close any keep-awake
        // span left open by a previous run that was killed while holding the Mac
        // awake, so the awake total stays honest.
        LoginItem.ensureDefaultOnFirstLaunch()
        if let lastAlive = UserDefaults.standard.object(forKey: "lastHeartbeat") as? Date {
            PowerLog.closeOpenSpan(lastAlive: lastAlive)
            HoldLog.closeOpenSpan(lastAlive: lastAlive)
        }
        Task { [weak self] in await self?.refreshUsage(force: true) } // populate meters once at launch
        Task { [weak self] in await self?.checkForUpdates() }         // notify if a newer release exists
        viewLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshView()
                try? await Task.sleep(for: .seconds(Self.scanInterval))
            }
        }
        resumeLoop = Task { [weak self] in
            while !Task.isCancelled {
                // Jittered gap between resume attempts so resumes after a
                // reset spread out (and don't sync to a robotic beat).
                let gap = Self.paceSeconds(nil) * Double.random(in: 0.6...1.4)
                try? await Task.sleep(for: .seconds(gap))
                await self?.resumeTick()
            }
        }
    }

    /// Stalled sessions from all sources, scanned off the main thread.
    /// Conductor + Claude Desktop are cheap and run every call; the terminal
    /// transcript scan is heavier, so it's throttled and cached. Standalone
    /// transcripts also contain Conductor / Claude Desktop sessions, so we
    /// dedupe by Claude session id — the richer in-app source wins.
    private func combinedStalled() async -> [StalledSession] {
        var all = await Task.detached(priority: .utility) { () -> [StalledSession] in
            var a: [StalledSession] = []
            if let conductor = try? ConductorDB.findStalledSessions() { a += conductor }
            a += ClaudeDesktopDB.findStalledSessions()
            return a
        }.value

        if Date().timeIntervalSince(lastClaudeCodeScan ?? .distantPast) > 120 {
            cachedClaudeCode = await Task.detached(priority: .utility) {
                ClaudeCodeDB.findStalledSessions()
            }.value
            lastClaudeCodeScan = Date()
        }
        let seen = Set(all.map(\.claudeSessionID))
        all += cachedClaudeCode.filter { !seen.contains($0.claudeSessionID) }
        return all
    }

    /// Cheap 30s refresh: scan stalled sessions and recompute the decision
    /// from the CACHED usage. Deliberately does NOT hit the usage API — that
    /// endpoint is rate-limited, so we fetch it lazily (before a resume, when
    /// the popover opens, at launch) via `refreshUsage`.
    @discardableResult
    func refreshView() async -> Bool {
        let config = PolicyConfig.fromDefaults()
        UserDefaults.standard.set(Date(), forKey: "lastHeartbeat") // liveness proof
        stalled = await combinedStalled()
        await refreshBudgets()
        lastTick = Date()
        let fresh = recomputeDecision(config: config)

        // Hold the Mac awake only around a reset that stalled work is waiting
        // for, or while that work is actually being resumed. Not all week.
        let waiting = waitingCount(config: config)
        let keepAwake = !signInExpired && ResetWatch.shouldKeepAwake(
            armed: armed, waiting: waiting, budgetAllows: fresh && decision?.resume == true,
            nextReset: usage?.sevenDay.resetsAt, now: Date())
        if keepAwake != lastKeepAwake {
            PowerLog.record(awake: keepAwake) // durable proof of when we held the Mac awake
            lastKeepAwake = keepAwake
        }
        PowerManager.preventIdleSleep(keepAwake)
        // "Done for now": nothing left to try, or the week says stop. Either
        // way, report what the unattended loop already did.
        postResumeSummaryIfDone(done: waiting == 0 || !(fresh && decision?.resume == true))
        return fresh
    }

    /// Stalled sessions the unattended loop would still try today (not over
    /// the per-session or per-day caps). Zero means nothing is waiting on us.
    func waitingCount(config: PolicyConfig) -> Int {
        let ledger = ResumeLedger.load()
        guard ledger.total < config.maxResumesPerDay else { return 0 }
        return stalled.filter {
            ledger.count(for: $0.stallKey) < config.maxResumesPerSession
                && ledger.failureCount(for: $0.stallKey) < config.maxResumesPerSession
        }.count
    }

    /// Check GitHub Releases for a newer version. Throttled to once every 6h
    /// (persisted across launches) so it can't rate-limit GitHub; a manual
    /// check from settings passes `force`. Sets `update` when one is available.
    func checkForUpdates(force: Bool = false) async {
        guard !isScreenshot else { return }
        let now = Date()
        if !force, let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date,
           now.timeIntervalSince(last) < UpdateChecker.minCheckInterval {
            return
        }
        UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        guard let latest = await UpdateChecker.fetchLatest() else { return }
        update = UpdateChecker.isNewer(latest.version, than: UpdateChecker.currentVersion)
            ? latest : nil
    }

    /// Fetch usage with three guards against rate-limiting the shared `/usage`
    /// endpoint: a cache window, randomized jitter (so we don't sync up with
    /// Conductor / Claude Code / Claude Desktop polling the same endpoint),
    /// and exponential backoff on a 429. Returns whether usage is fresh
    /// enough to act on.
    @discardableResult
    func refreshUsage(force: Bool) async -> Bool {
        let now = Date()
        let inBackoff = (usageBackoffUntil.map { now < $0 }) ?? false
        let age = now.timeIntervalSince(lastUsageFetchAt ?? .distantPast)
        let attemptAge = now.timeIntervalSince(lastUsageAttemptAt ?? .distantPast)
        let threshold = Self.usageRefreshInterval + usageJitter
        if Self.shouldFetchUsage(
            force: force, hasUsage: usage != nil, fresh: usageIsFresh(now),
            inBackoff: inBackoff, age: age, threshold: threshold,
            attemptAge: attemptAge, minAttemptGap: Self.minUsageAttemptGap
        ) {
            lastUsageAttemptAt = now
            do {
                usage = try await UsageClient.fetchUsage()
                lastUsageFetchAt = Date()
                usageBackoffUntil = nil
                usageBackoffStep = 0
                signInExpired = false
                usageJitter = Double(Int.random(in: 0...45)) // re-roll for next time
            } catch let error as UsageError where error.isRateLimited {
                let delays = [300.0, 600.0, 1200.0, 1800.0] // 5, 10, 20, 30 min
                usageBackoffStep = min(usageBackoffStep + 1, delays.count)
                usageBackoffUntil = now.addingTimeInterval(delays[usageBackoffStep - 1])
                log("Usage rate-limited, backing off \(Int(delays[usageBackoffStep - 1] / 60))m")
            } catch let error as UsageError where error.isSignInExpired {
                // The fetch was skipped/refused because the Claude Code token
                // expired. No backoff (the call is cheap and we never hit the
                // network) — just surface it so the user knows to refresh.
                signInExpired = true
            } catch {
                // transient / network — keep the cached reading
            }
        }
        _ = recomputeDecision(config: PolicyConfig.fromDefaults())
        await refreshBudgets() // the Claude meter tracks the fresh reading at once
        return usageIsFresh(now)
    }

    /// Whether to attempt a usage fetch. The 429 backoff throttles polling of
    /// data we ALREADY have fresh, but must never strand us on a stale reading:
    /// a stale "you're maxed" value makes us hold for hours when there's really
    /// headroom (max backoff is 30m, staleness is 15m, so a backoff alone
    /// guarantees such a window). Once the cached data is stale, always retry.
    nonisolated static func shouldFetchUsage(
        force: Bool, hasUsage: Bool, fresh: Bool,
        inBackoff: Bool, age: TimeInterval, threshold: TimeInterval,
        attemptAge: TimeInterval = .greatestFiniteMagnitude, minAttemptGap: TimeInterval = 0
    ) -> Bool {
        // Floor the call rate: never fetch more than once per minAttemptGap,
        // even a forced one, so rapid popover opens can't fire a /usage call per
        // open. This holds even before the first SUCCESS — a failed first fetch
        // (429, signed out, network) leaves `usage` nil, and that must NOT exempt
        // the floor. A true first load (never attempted) has attemptAge of
        // .greatestFiniteMagnitude, so it stays exempt and the meters populate.
        if attemptAge < minAttemptGap { return false }
        // The 429 backoff throttles polling, but must never strand us on a STALE
        // reading (a stale "you're maxed" value would hold for hours). So it
        // blocks when the data is fresh OR when we have no reading at all, and
        // stands down only to recover a stale one.
        let blockedByBackoff = inBackoff && (fresh || !hasUsage)
        return !blockedByBackoff && (force || !hasUsage || age > threshold)
    }

    /// Seconds between unattended resume attempts, clamped to a sane 5 to 20
    /// minute range (jitter is added at the call site). Default 10 minutes.
    nonisolated static func paceSeconds(_ minutes: Double?) -> TimeInterval {
        min(20, max(5, minutes ?? 10)) * 60
    }

    /// Stop a resume pass after a success only when it's NOT manual: an auto
    /// pass resumes one session per tick to spread the work out, while a
    /// manual "Resume now" resumes the whole list.
    nonisolated static func shouldStopPass(manual: Bool, handedToApp: Bool, resultOK: Bool) -> Bool {
        !manual && (handedToApp || resultOK)
    }

    /// Whether the auto loop should resume this session now (the budget gate
    /// is checked by the caller). A session stalled on a TRANSIENT server
    /// rate-limit ("temporarily limiting requests") gets a cool-down first, so
    /// the loop never bounces straight back into the same limit. Manual
    /// "Resume now" skips this (it doesn't run through here).
    nonisolated static func autoResumeEligible(
        _ session: StalledSession, now: Date, lastResumedAt: Date? = nil
    ) -> Bool {
        if session.kind == .transient, let at = session.stalledAt,
           now.timeIntervalSince(at) < transientCooldown { return false }
        // Don't re-fire the SAME session too soon. A headless resume doesn't
        // clear the host app's stalled flag, so without this the loop would
        // re-resume it every tick and pile inference onto the rate limit.
        if let last = lastResumedAt, now.timeIntervalSince(last) < resumeCooldown { return false }
        return true
    }

    func usageIsFresh(_ now: Date = Date()) -> Bool {
        guard usage != nil, let at = lastUsageFetchAt else { return false }
        return now.timeIntervalSince(at) <= Self.usageStaleAfter
    }

    @discardableResult
    private func recomputeDecision(config: PolicyConfig) -> Bool {
        let now = Date()
        if let snapshot = usage, usageIsFresh(now) {
            let result = Policy.shouldResume(usage: snapshot, config: config, now: now)
            decision = result
            // Waiting for the reset is the normal rest on a weekly plan, not a
            // problem; only a mid-week .holding is worth a durable "why" record.
            HoldLog.record(reason: (!result.resume && result.state == .holding) ? result.reason : "")
            return true
        }
        let reason: String
        if signInExpired {
            reason = "Claude sign-in expired. Open Claude Code or Conductor to refresh"
        } else if usage == nil {
            reason = "Checking usage…"
        } else {
            reason = "Usage data is stale, holding"
        }
        decision = Decision(resume: false, reason: reason, state: .checking)
        // Unlike .holding above, .checking here can be a brief, normal blip (a
        // fetch in flight) or the exact multi-hour failure this log exists to
        // catch (e.g. a sign-in that stayed expired for hours). Recording it
        // is harmless either way: HoldLog dedupes unchanged reasons, so a
        // fast-clearing blip collapses to one short-lived entry.
        HoldLog.record(reason: reason)
        return false
    }

    /// The budget-gated resume pass, run on the slower resume loop.
    func resumeTick() async {
        await refreshView()
        // Fresh usage required to auto-resume (respects backoff; fail closed).
        guard await refreshUsage(force: true) else { return }
        guard armed, let usage else { return }
        let config = PolicyConfig.fromDefaults()
        let now = Date()
        // Never overspend: the week must have room (stop line + pace).
        guard Policy.shouldResume(usage: usage, config: config, now: now).resume else { return }
        let ledger = ResumeLedger.load(now: now)
        let eligible = stalled.filter {
            Self.autoResumeEligible($0, now: now,
                                    lastResumedAt: ledger.lastResumed[$0.stallKey] ?? lastResumedAt[$0.ledgerKey])
        }
        guard !eligible.isEmpty else { return }
        await resumeStalledSessions(sessions: eligible, config: config, manual: false)
    }

    /// Manual "Resume now": your explicit call — resume regardless of our
    /// active-hours and budget gates (only Anthropic's real limit can stop a
    /// resume, and that's reported per-session). Crucially it does NOT depend
    /// on a usage fetch, which can itself be rate-limited.
    func tick(manual: Bool) async {
        isWorking = true
        defer { isWorking = false }
        await refreshView() // best-effort display refresh; never gates the resume
        await refreshUsage(force: false) // freshen the meters (throttled), non-blocking
        guard !stalled.isEmpty else { log("Nothing stalled to resume right now"); return }
        let config = PolicyConfig.fromDefaults()
        await resumeStalledSessions(sessions: stalled, config: config, manual: manual)
    }

    var uiResumeEnabled: Bool {
        UserDefaults.standard.object(forKey: "uiResume") == nil
            || UserDefaults.standard.bool(forKey: "uiResume")
    }

    private func resumeStalledSessions(
        sessions: [StalledSession], config: PolicyConfig, manual: Bool
    ) async {
        guard !isResuming else {
            if manual { log("Busy resuming, try again in a moment") } // don't drop silently
            return
        } // never run two passes at once
        isResuming = true
        defer { isResuming = false }

        let useUI = uiResumeEnabled && UIResumer.hasAccessibilityPermission

        // Locating the claude CLI may spawn a login shell, so do it off the
        // main thread and only when headless is actually needed (UI mode
        // defers it until a UI resume fails).
        var resolvedClaudePath: String??  // nil = not looked up yet
        func claudeBinary() async -> String? {
            if let cached = resolvedClaudePath { return cached }
            let found = await Task.detached(priority: .utility) {
                Resumer.findClaudeBinary()
            }.value
            resolvedClaudePath = .some(found)
            return found
        }
        var ledger = ResumeLedger.load()
        var attemptsThisPass = 0 // bound a pass when many sessions fail in a row

        for session in sessions {
            // Daily caps protect the unattended loop; a manual click is your
            // explicit call, so it bypasses them.
            if !manual {
                guard ledger.total < config.maxResumesPerDay else {
                    log("Daily cap reached (\(config.maxResumesPerDay) resumes)")
                    break
                }
                guard attemptsThisPass < Self.maxAttemptsPerPass else { break } // try again next tick
                guard ledger.count(for: session.stallKey) < config.maxResumesPerSession else {
                    continue // this stall has had its tries
                }
                guard ledger.failureCount(for: session.stallKey) < config.maxResumesPerSession else {
                    continue // keeps failing: stop hammering it
                }
            }
            attemptsThisPass += 1

            currentlyResuming = session.title
            log("▶ Resuming \(session.title) [\(session.source.label)]")
            var result = ResumeResult(ok: false, detail: "not attempted")
            var handedToApp = false // resumed inside the host app — chat in sync

            switch session.source {
            case .claudeDesktop:
                // Faithful, in-sandbox resume only — no headless fallback,
                // since a host resume would drop Claude Desktop's sandbox.
                if ClaudeDesktopResumer.hasAccessibilityPermission {
                    result = await Task.detached(priority: .utility) {
                        ClaudeDesktopResumer.resume(session: session)
                    }.value
                    handedToApp = result.ok
                } else {
                    result = ResumeResult(ok: false, detail: "needs Accessibility access")
                }
            case .conductor:
                if useUI {
                    result = await Task.detached(priority: .utility) {
                        UIResumer.resume(session: session)
                    }.value
                    handedToApp = result.ok
                    if !result.ok {
                        log(result.pressed
                            ? "↻ pressed Retry, not confirmed yet (\(result.detail)); no headless fallback"
                            : "↻ UI resume failed (\(result.detail)), falling back to headless")
                    }
                }
                if !result.ok, !result.pressed, let claudePath = await claudeBinary() {
                    result = await Task.detached(priority: .utility) {
                        Resumer.resume(session: session, claudePath: claudePath, config: config)
                    }.value
                }
            case .claudeCode:
                // Terminal sessions aren't sandboxed → headless is faithful.
                if let claudePath = await claudeBinary() {
                    result = await Task.detached(priority: .utility) {
                        Resumer.resume(session: session, claudePath: claudePath, config: config)
                    }.value
                } else {
                    result = ResumeResult(ok: false, detail: "claude CLI not found")
                }
            }

            currentlyResuming = nil
            if handedToApp {
                log("✓ \(session.title) resumed inside \(session.source.label), chat stays in sync")
            } else {
                log(result.ok ? "✓ \(session.title) finished a run" : "✗ \(session.title): \(result.detail)")
            }

            // A manual click bypasses the cap CHECK, so it must not spend the
            // cap BUDGET either: the daily ledger exists to bound the
            // UNATTENDED loop, not your explicit choices. Manual still logs to
            // history.
            if result.ok {
                lastResumedAt[session.ledgerKey] = Date() // space out re-firing this session
                ResumeHistory.record(ResumeEvent(
                    date: Date(), title: session.title,
                    kind: session.kind == .transient ? "transient" : "usage_limit",
                    inConductor: handedToApp
                ))
            }
            if !manual {
                // Only a SUCCESS spends the day's budget. A failure is tracked
                // separately so a transient blip can't burn the caps.
                ledger = result.ok
                    ? ledger.recordingSuccess(session.stallKey)
                    : ledger.recordingFailure(session.stallKey)
                ledger.save()
                if result.ok {
                    ResumeSummary.recordUnattended(key: session.ledgerKey, title: session.title, inApp: handedToApp)
                }
            }

            // Spread it out: an AUTO pass resumes ONE session per tick so the
            // budget trickles out instead of bursting; the next tick
            // takes the next session. A MANUAL pass ("Resume now") keeps going
            // through the whole list, so clicking it resumes everything.
            if Self.shouldStopPass(manual: manual, handedToApp: handedToApp, resultOK: result.ok) {
                log(handedToApp
                    ? "Handed to \(session.source.label), next session shortly"
                    : "Resumed \(session.title), spacing out, next at the next cycle")
                break
            }
            // Manual passes, and failed auto attempts, continue to the next.
        }
        stalled = await combinedStalled()
    }

    /// Once nothing is left waiting, tell the user what the unattended loop
    /// did since the last note: one notification per run of resumes, not one
    /// per session.
    private func postResumeSummaryIfDone(done: Bool) {
        guard done, !isResuming, let summary = ResumeSummary.takeIfAny() else { return }
        Notifications.postResumeSummary(count: summary.count, sampleTitle: summary.title,
                                        backgroundCount: summary.background)
        log("Resumed \(summary.count) stalled session\(summary.count == 1 ? "" : "s")")
    }

    func log(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        activity.insert("\(stamp)  \(message)", at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}

/// Ledger of unattended resumes, persisted so relaunching can't bypass the
/// caps. Two different budgets:
///   • a DAILY total (10 by default), keyed by the local calendar day, and
///   • per-STALL attempts (3 by default), keyed by `StalledSession.stallKey`
///     and NOT reset at midnight: one stall gets three tries, full stop. (A
///     headless resume doesn't clear Conductor's stalled flag, so a per-day
///     count would re-run the same finished session every day.)
/// Successes and failures are tracked separately: successes spend the caps,
/// failures only stop us retrying a genuinely broken stall forever.
struct ResumeLedger {
    let key: String              // local day of `dayTotal`
    let dayTotal: Int            // successful unattended resumes today
    let counts: [String: Int]    // successful resumes per stall
    let failures: [String: Int]  // failed attempts per stall
    /// Last successful resume per stall, so the cool-down survives a relaunch.
    let lastResumed: [String: Date]

    init(key: String, dayTotal: Int = 0, counts: [String: Int] = [:], failures: [String: Int] = [:],
         lastResumed: [String: Date] = [:]) {
        self.key = key
        self.dayTotal = dayTotal
        self.counts = counts
        self.failures = failures
        self.lastResumed = lastResumed
    }

    var total: Int { dayTotal }

    func count(for stallKey: String) -> Int { counts[stallKey] ?? 0 }
    func failureCount(for stallKey: String) -> Int { failures[stallKey] ?? 0 }

    func recordingSuccess(_ stallKey: String, at date: Date = Date()) -> ResumeLedger {
        var updated = counts
        updated[stallKey, default: 0] += 1
        var last = lastResumed
        last[stallKey] = date
        return ResumeLedger(key: key, dayTotal: dayTotal + 1, counts: updated,
                            failures: failures, lastResumed: last)
    }

    func recordingFailure(_ stallKey: String) -> ResumeLedger {
        var updated = failures
        updated[stallKey, default: 0] += 1
        return ResumeLedger(key: key, dayTotal: dayTotal, counts: counts,
                            failures: updated, lastResumed: lastResumed)
    }

    /// The local calendar day. Formatted in the SAME calendar as the date
    /// (`.iso8601` would format in UTC and roll the day at the wrong hour).
    static func currentKey(now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A new day resets only the daily total. Per-stall entries are kept
    /// until the stall itself is too old to matter.
    static func load(now: Date = Date(), defaults: UserDefaults = .standard) -> ResumeLedger {
        let key = currentKey(now: now)
        let sameDay = defaults.string(forKey: "ledgerDay") == key
        let last = (defaults.dictionary(forKey: "ledgerLastResumed") as? [String: Date] ?? [:])
            .filter { now.timeIntervalSince($0.value) < StalledSession.maxAge }
        let live = Set(last.keys)
        let keep: ([String: Int]) -> [String: Int] = { dict in
            // Drop entries for stalls with no recent resume and no failures worth keeping.
            dict.count > 500 ? dict.filter { live.contains($0.key) } : dict
        }
        return ResumeLedger(
            key: key,
            dayTotal: sameDay ? defaults.integer(forKey: "ledgerDayTotal") : 0,
            counts: keep(defaults.dictionary(forKey: "ledgerCounts") as? [String: Int] ?? [:]),
            failures: keep(defaults.dictionary(forKey: "ledgerFailures") as? [String: Int] ?? [:]),
            lastResumed: last
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(key, forKey: "ledgerDay")
        defaults.set(dayTotal, forKey: "ledgerDayTotal")
        defaults.set(counts, forKey: "ledgerCounts")
        defaults.set(failures, forKey: "ledgerFailures")
        defaults.set(lastResumed, forKey: "ledgerLastResumed")
    }
}

/// Unattended resumes not yet reported to the user, persisted so a relaunch
/// mid-run still ends in one honest "Resumed 3 stalled sessions" note.
/// Counts distinct sessions, not attempts: re-resuming one session three
/// times is one session.
enum ResumeSummary {
    struct Pending: Equatable { let count: Int; let title: String?; let background: Int }
    private static let keysKey = "summaryKeys"
    private static let backgroundKeysKey = "summaryBackgroundKeys"
    private static let titleKey = "summaryTitle"

    static func recordUnattended(key: String, title: String, inApp: Bool, defaults: UserDefaults = .standard) {
        func add(_ k: String) {
            var keys = Set(defaults.stringArray(forKey: k) ?? [])
            keys.insert(key)
            defaults.set(Array(keys), forKey: k)
        }
        add(keysKey)
        if !inApp { add(backgroundKeysKey) }
        defaults.set(title, forKey: titleKey)
    }

    /// Returns what's pending and clears it, or nil when nothing is.
    static func takeIfAny(defaults: UserDefaults = .standard) -> Pending? {
        let keys = defaults.stringArray(forKey: keysKey) ?? []
        guard !keys.isEmpty else { return nil }
        let pending = Pending(count: keys.count, title: defaults.string(forKey: titleKey),
                              background: (defaults.stringArray(forKey: backgroundKeysKey) ?? []).count)
        [keysKey, backgroundKeysKey, titleKey].forEach { defaults.removeObject(forKey: $0) }
        return pending
    }
}
