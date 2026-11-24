import ServiceManagement
import SwiftUI

enum AboutLinks {
    static let linkedIn = URL(string: "https://www.linkedin.com/in/jkkorn")!
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/jkkorn")!
}

/// Design tokens — one 4pt spacing scale and one card surface, so spacing
/// and chrome are systematic instead of per-view magic numbers.
enum Design {
    static let xs: CGFloat = 2   // within a tight text stack
    static let s: CGFloat = 4    // label → control
    static let m: CGFloat = 8    // within a section
    static let l: CGFloat = 12   // card padding / section gap
    static let xl: CGFloat = 16  // window padding
    static let cardRadius: CGFloat = 8
}

extension Color {
    /// One semantic ramp for "how full is this budget": green = headroom,
    /// amber = approaching the ceiling, red = at/over. Indigo is reserved
    /// for the brand (the moon), never for status.
    static func usageStatus(_ pct: Double) -> Color {
        switch pct {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings: Bool
    @State private var showActivity: Bool
    @AppStorage("setupDismissed") private var setupDismissed = false
    // AXIsProcessTrusted() is only re-read on render, so poll while the card is
    // showing — the checkmark should flip within seconds of granting, matching
    // the identical pattern in SettingsPane below.
    @State private var hasAccessibility = UIResumer.hasAccessibilityPermission
    private let setupPermissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @State private var notificationsAllowed = true // assume yes until checked, so the card doesn't flash
    private let maxStalledRows = 6 // render this many; the rest auto-resume

    init(showSettings: Bool = false, showActivity: Bool = false) {
        _showSettings = State(initialValue: showSettings)
        _showActivity = State(initialValue: showActivity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.l) {
            header
            setupCard
            usageSection
            nightWatchSection
                .revealOnAppear(index: 5)
            if showActivity { activityLog }
            Divider()
            footer
                .revealOnAppear(index: 6)
        }
        .padding(Design.l)
        .frame(width: 340)
        .background(PopoverBackdrop().ignoresSafeArea())
        // Opening the popover is an explicit "show me now". If the cached
        // reading is stale, force a refresh (which also punches through a 429
        // backoff); if it's already fresh, stay throttled to avoid hammering.
        // Never in screenshot mode — docs must use curated demo data, not live.
        .onAppear {
            guard !state.isScreenshot else { return }
            Task { await state.refreshUsage(force: !state.usageIsFresh()) }
        }
        .onReceive(setupPermissionTimer) { _ in
            hasAccessibility = UIResumer.hasAccessibilityPermission
            if !state.isScreenshot {
                Task { notificationsAllowed = await NotificationPermission.isAllowed() }
            }
        }
        .task {
            guard !state.isScreenshot else { return }
            notificationsAllowed = await NotificationPermission.isAllowed()
        }
    }

    /// The night watch, as one labelled section under your usage.
    private var nightWatchSection: some View {
        VStack(alignment: .leading, spacing: Design.m) {
            Text("Night watch").font(.headline)
            decisionRow
            stalledSection
        }
    }

    // Living night-sky header: a drifting aurora + twinkling starfield, with
    // the brand wordmark (bottom-left), the arm control (bottom-right), and a
    // glowing moon (top-right). Each is its own corner so nothing overlaps.
    private var header: some View {
        ZStack(alignment: .topTrailing) {
            NightSkyView(armed: state.armed)
            // Scrim: darkens the top (moon/toggle) and bottom (wordmark) so
            // white content stays legible even on the bright daytime sky,
            // while the middle keeps the sky's color.
            LinearGradient(
                colors: [.black.opacity(0.22), .black.opacity(0.0), .black.opacity(0.40)],
                startPoint: .top, endPoint: .bottom
            )
            // One row, vertically centred: wordmark, moon, arm switch. (The
            // moon used to sit in its own top corner, which collided with the
            // switch once the header got shorter.)
            HStack(alignment: .center, spacing: Design.l) {
                VStack(alignment: .leading, spacing: Design.xs) {
                    Text("Night Conductor")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                        .contentTransition(.opacity)
                }
                Spacer()
                GlowingMoon(armed: state.armed, size: 24)
                VStack(alignment: .trailing, spacing: Design.xs) {
                    Toggle("Arm night watch", isOn: Binding(
                        get: { state.armed },
                        // Set directly, no wrapping spring: the old spring animated the
                        // whole armed-driven header (mesh sky + moon shadows) for 0.35s
                        // of full re-renders, which made the toggle feel sluggish. The
                        // sub-views animate their own armed change cheaply.
                        set: { state.armed = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.green)
                    .help("Arm or disarm the night watch")
                    Text(state.armed ? "ARMED" : "PAUSED")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(state.armed ? Color.green : .white.opacity(0.6))
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, Design.l)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 76) // usage is the hero now; the sky is the brand, not the content
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5) // crisp edge
        )
    }

    /// First-run guidance. The automatic steps show as done for reassurance;
    /// the one manual step (Accessibility) carries the action. Reuses glassCard
    /// so it matches the rest of the popover, and hides once Accessibility is
    /// granted or the user dismisses it.
    @ViewBuilder
    private var setupCard: some View {
        // Demo hook: the offscreen design render forces the card (it is hidden in
        // real screenshot/doc mode) so both states can be seen and tuned.
        if let demo = state.screenshotSetup {
            setupCardBody(blocked: demo == "blocked", blockedCount: 2, armed: true,
                          launchAtLogin: true, usageReady: true, accessibility: false,
                          notifications: false, onDismiss: demo == "blocked" ? nil : {})
        } else {
            // Claude Desktop (Cowork) resume is Accessibility-only, no fallback, so
            // a stalled Cowork session with Accessibility off is fully blocked, and
            // the card re-raises even if dismissed. Conductor sessions fall back to
            // headless, so they are not blocked, just invisible in chat.
            let blockedCount = state.stalled.filter { $0.source == .claudeDesktop }.count
            let blocked = !hasAccessibility && blockedCount > 0
            if SetupStatus.shouldShow(
                accessibilityGranted: hasAccessibility, dismissed: setupDismissed,
                isScreenshot: state.isScreenshot, hasBlockedSessions: blocked,
                notificationsAllowed: notificationsAllowed
            ) {
                setupCardBody(
                    blocked: blocked, blockedCount: blockedCount, armed: state.armed,
                    launchAtLogin: LoginItem.isEnabled, usageReady: state.usage != nil,
                    accessibility: hasAccessibility, notifications: notificationsAllowed,
                    onDismiss: blocked ? nil : { withAnimation { setupDismissed = true } }
                )
            }
        }
    }

    /// The card body, values passed explicitly so the offscreen render can show
    /// both the calm "Finish setup" and the urgent amber "Action needed" states.
    /// The one manual step (Accessibility) is highlighted as pending so the eye
    /// lands on the single thing left to do.
    private func setupCardBody(
        blocked: Bool, blockedCount: Int, armed: Bool, launchAtLogin: Bool,
        usageReady: Bool, accessibility: Bool, notifications: Bool, onDismiss: (() -> Void)?
    ) -> some View {
        let accent: Color = blocked ? .orange : .indigo
        return VStack(alignment: .leading, spacing: Design.m) {
            HStack(spacing: Design.s) {
                Image(systemName: blocked ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.caption).foregroundStyle(accent)
                Text(blocked ? "Action needed" : "Finish setup")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let onDismiss {  // no dismiss while a session is actually blocked
                    Button(action: onDismiss) { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
                }
            }
            if blocked {
                Text("\(blockedCount) Claude app session\(blockedCount == 1 ? "" : "s") stalled that I can't resume without Accessibility.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Design.s) {
                setupStep(done: armed, "Night watch armed")
                setupStep(done: launchAtLogin, "Launches at login")
                setupStep(done: usageReady, "Reading your usage")
                setupStep(done: notifications, pending: !notifications,
                          "Notifications, so budget alerts reach you")
                setupStep(done: accessibility, pending: !accessibility,
                          "Accessibility, so resumes show inside the app")
            }
            if !blocked && !accessibility {
                Text("Without Accessibility, resumes still run, just in the background instead of in the app's chat.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Design.m) {
                if !notifications {
                    Button("Allow Notifications") { Task { await NotificationPermission.requestOrOpenSettings() } }
                        .controlSize(.small).tint(accent)
                }
                if !accessibility {
                    Button("Open Accessibility Settings…") { UIResumer.openAccessibilitySettings() }
                        .controlSize(.small).tint(accent)
                }
            }
        }
        .glassCard(tint: blocked ? .orange : nil)
    }

    private func setupStep(done: Bool, pending: Bool = false, _ label: String) -> some View {
        HStack(spacing: Design.s) {
            Image(systemName: done ? "checkmark.circle.fill"
                                   : (pending ? "circle.dashed" : "circle"))
                .font(.caption)
                .foregroundStyle(done ? Color.green : (pending ? Color.orange : Color.secondary))
            Text(label)
                .font(.caption)
                .foregroundStyle(done ? Color.secondary : Color.primary)
                .strikethrough(done, color: .secondary)
        }
    }

    private var subtitle: String {
        if let resuming = state.currentlyResuming { return "Conducting: \(resuming)…" }
        if state.isWorking { return "Checking…" }
        guard state.armed else { return "Night watch paused" }
        let config = PolicyConfig.fromDefaults()
        let watchingNow = state.aroundTheClock || Policy.inActiveHours(
            hour: Calendar.current.component(.hour, from: Date()), start: config.startHour, end: config.endHour)
        return watchingNow ? "Watching while you sleep" : "Armed for tonight"
    }

    /// Every AI subscription we can read, one card each (BudgetViews.swift).
    private var usageSection: some View { BudgetsSection() }

    private var decisionRow: some View {
        HStack(spacing: Design.m) {
            Image(systemName: decisionIcon)
                .foregroundStyle(decisionColor)
                .contentTransition(.symbolEffect(.replace))
            Text(state.decision?.reason ?? "Waiting for first check…")
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(2)
                .contentTransition(.opacity)
        }
        .glassCard(tint: decisionColor)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: decisionColor)
    }

    private var decisionColor: Color {
        switch state.decision?.state {
        case .resuming: return .green
        case .standingBy: return .indigo   // calm & nocturnal — not a warning
        case .holding: return .orange
        case .checking, .none: return .secondary
        }
    }

    private var decisionIcon: String {
        switch state.decision?.state {
        case .resuming: return "checkmark.circle.fill"
        case .standingBy: return "moon.stars.fill" // resting; wakes for the night
        case .holding: return "pause.circle.fill"
        case .checking, .none: return "clock"
        }
    }

    @ViewBuilder
    private var stalledSection: some View {
        if state.stalled.isEmpty {
            HStack(spacing: Design.m) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.secondary)
                Text("No stalled sessions, all quiet")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, Design.s)
        } else {
            VStack(alignment: .leading, spacing: Design.m) {
                HStack {
                    Text("Stalled at the limit").font(.headline)
                    Spacer()
                    Text("\(state.stalled.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
                // Render rows directly (a ScrollView collapses to zero height
                // in a self-sizing popover). Cap the count; the rest auto-
                // resume on their own cadence.
                ForEach(state.stalled.prefix(maxStalledRows)) { session in
                    stalledRow(session)
                }
                if state.stalled.count > maxStalledRows {
                    Text("+ \(state.stalled.count - maxStalledRows) more, pin the ones you want resumed by day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
                Button {
                    Task { await state.tick(manual: true) }
                } label: {
                    Label(state.isWorking ? "Working…" : "Resume now",
                          systemImage: state.isWorking ? "hourglass" : "play.fill")
                        .contentTransition(.opacity)
                }
                .buttonStyle(GlowButtonStyle(disabled: state.isWorking))
                .disabled(state.isWorking)
                .help("Resumes now, bypasses the schedule and budget gates")
            }
        }
    }

    @ViewBuilder
    private func stalledRow(_ session: StalledSession) -> some View {
        let accent: Color = session.kind == .transient ? .yellow : .orange
        let pinned = state.isPinned(session)
        HStack(spacing: Design.m) {
            Image(systemName: session.kind.icon)
                .font(.title3)
                .foregroundStyle(accent.gradient)
            VStack(alignment: .leading, spacing: Design.xs) {
                Text(session.title).font(.body).lineLimit(1)
                HStack(spacing: Design.s) {
                    Text(session.workspaceName)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(session.source.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                    Text(session.kind.shortLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(accent.opacity(0.15), in: Capsule())
                }
            }
            Spacer()
            // Pin = auto-resume this session around the clock (not just at night).
            Button(pinned ? "Stop auto-resuming any time" : "Auto-resume any time",
                   systemImage: pinned ? "repeat.circle.fill" : "repeat.circle") {
                state.togglePin(session)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .foregroundStyle(pinned ? Color.indigo : .secondary)
            .buttonStyle(.plain)
            .accessibilityAddTraits(pinned ? .isSelected : [])
            .help(pinned
                  ? "Auto-resuming any time, click to stop"
                  : "Auto-resume this session any time (not just at night)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .hoverLift()
    }

    // The Activity panel shows the DURABLE resume history (what was resumed and
    // when), read from the same persisted store as the weekly stat. It used to
    // render only `state.activity` — the in-memory session log, which is empty
    // on every launch, so it looked blank even after the watch resumed all
    // night. The live session log is kept below as a dim, secondary trace.
    private var activityLog: some View {
        let resumes = ResumeHistory.recent(limit: 40)
        return ScrollView {
            VStack(alignment: .leading, spacing: Design.m) {
                watchProof
                VStack(alignment: .leading, spacing: 4) {
                    activitySectionLabel("Recent resumes")
                    if resumes.isEmpty {
                        Text("Nothing resumed yet. Sessions you leave stalled on the limit show up here once the watch picks them back up.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(Array(resumes.enumerated()), id: \.offset) { _, event in
                            ActivityRow(event: event)
                        }
                    }
                }
                if !state.activity.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        activitySectionLabel("This session")
                        ForEach(state.activity.prefix(12), id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                                .foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
    }

    private func activitySectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption).bold()
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }

    /// Visible proof the watch is real: whether it's holding the Mac awake right
    /// now, and how long it kept it awake plus how many sessions it resumed in
    /// the last 24 hours. Reads durable stores, so it survives relaunches.
    private var watchProof: some View {
        let holding = PowerManager.isHoldingAwake
        let since = Date().addingTimeInterval(-24 * 3600)
        let awake = PowerLog.awakeSeconds(since: since)
        let resumes = ResumeHistory.count(within: 24 * 3600)
        let background = ResumeHistory.backgroundCount(within: 24 * 3600)
        let longestHold = HoldLog.longestHold(since: since)
        return VStack(alignment: .leading, spacing: 4) {
            activitySectionLabel("Last 24 hours")
            HStack(spacing: Design.s) {
                Image(systemName: holding ? "bolt.horizontal.fill" : "pause.circle")
                    .font(.caption)
                    .foregroundStyle(holding ? Color.indigo : Color.secondary)
                Text(holding ? "Keeping your Mac awake now"
                             : "Not holding the Mac awake right now")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Kept awake \(awakeText(awake)) and resumed \(resumes) session\(resumes == 1 ? "" : "s").")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if background > 0 {
                Text("Background resumes land in your workspace, not the chat.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only shown when something actually blocked resuming — silent on
            // a normal night, so this reads as a real answer to "why didn't it
            // resume anything," not routine noise.
            if let hold = longestHold, hold.seconds >= 60 {
                HStack(alignment: .top, spacing: Design.s) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                    Text("Held \(awakeText(hold.seconds)): \(hold.reason)")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func awakeText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        guard minutes >= 1 else { return "under a minute" }
        let hours = minutes / 60, rem = minutes % 60
        return hours > 0 ? "\(hours)h \(rem)m" : "\(rem)m"
    }

    private var footer: some View {
        VStack(spacing: Design.m) {
            if showSettings { SettingsPane() }
            HStack {
                // No animation here: animated height changes make the
                // MenuBarExtra window dismiss itself on some macOS versions.
                ToolbarTextButton(systemName: "gearshape", label: "Settings", isOn: showSettings) {
                    showSettings.toggle()
                }
                .accessibilityIdentifier("settingsButton")
                ToolbarTextButton(systemName: "list.bullet.rectangle", label: "Activity", isOn: showActivity) {
                    showActivity.toggle()
                }
                .accessibilityIdentifier("activityButton")

                Spacer()
                if let tick = state.lastTick {
                    Text("Updated \(tick.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.fill, value: tick)
                }
                Spacer()

                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}

/// One row in the Activity panel: the brand moon (the night watch did this),
/// the session title, an "in app" tag when the resume landed inside Conductor
/// or the Claude app (so the chat stayed in sync), and a day-aware timestamp.
private struct ActivityRow: View {
    let event: ResumeEvent

    var body: some View {
        HStack(spacing: Design.m) {
            Image(systemName: "moon.fill")
                .font(.caption)
                .foregroundStyle(Color.indigo)
                .accessibilityHidden(true)
            Text(event.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Design.s)
            if event.inConductor {
                Text("in app")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(Self.stamp(event.date))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
    }

    /// Day-aware so each row stays one line and is unambiguous across nights:
    /// just the time for today, weekday + time within the past week, otherwise
    /// a short date.
    static func stamp(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// A footer button with its name visible, so nobody has to guess which icon
/// is Settings. Highlighted while its panel is open.
struct ToolbarTextButton: View {
    let systemName: String
    let label: String
    var isOn: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemName)
                .font(.callout)
                .padding(.horizontal, Design.m).padding(.vertical, Design.s)
                .background((hovering || isOn) ? Color.secondary.opacity(0.18) : .clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? .primary : .secondary)
        .onHover { hovering = $0 }
    }
}

/// Version, credits and the shareable weekly card: useful, but not on every
/// open of the popover. Lives at the bottom of Settings.
struct AboutSection: View {
    @EnvironmentObject var state: AppState
    @State private var historyCleared = false

    var body: some View {
        VStack(spacing: Design.s) {
            HStack {
                Button("Share this week\u{2019}s stats", systemImage: "square.and.arrow.up") {
                    StatCardExporter.share()
                }
                Button(historyCleared ? "History cleared" : "Clear history",
                       systemImage: historyCleared ? "checkmark" : "trash") {
                    state.clearLocalHistory()
                    historyCleared = true
                }
                .disabled(historyCleared)
                .help("Forget resumed session titles, keep-awake logs and usage samples on this Mac")
            }
            .controlSize(.small)
            if !state.isScreenshot {  // the offscreen render has no bundle version
                Text("Night Conductor \(UpdateChecker.currentVersion)")
                    .foregroundStyle(.secondary)
            }
            Text("Made with ❤️ in Brazil")
            HStack(spacing: 5) {
                Link("Jonathan Korn", destination: AboutLinks.linkedIn).underline()
                Text("·")
                Link("Buy me a coffee", destination: AboutLinks.buyMeACoffee).underline()
            }
        }
        .frame(maxWidth: .infinity)
        .font(.caption)
        .foregroundStyle(.secondary)
        .tint(.secondary)
    }
}

enum ResetStyle { case time, date }

struct UsageMeter: View {
    let label: String
    let window: UsageWindow?
    let resetStyle: ResetStyle

    private var value: Double { window?.utilization ?? 0 }

    private var resetText: String {
        guard let resetsAt = window?.resetsAt else { return "" }
        switch resetStyle {
        case .time: return "resets \(resetsAt.formatted(date: .omitted, time: .shortened))"
        case .date: return "resets \(resetsAt.formatted(.dateTime.weekday(.wide).hour().minute()))"
        }
    }

    var body: some View {
        VStack(spacing: Design.m) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(resetText).font(.caption).foregroundStyle(.secondary)
                Text(window == nil ? "·" : UsageWording.used(value))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.usageStatus(value))
                    .contentTransition(.numericText())
            }
            // Custom bar: a flat semantic fill (the color IS the signal),
            // with a soft glow, a top sheen for a glassy read, and a spring
            // on value changes so it fills like liquid, not a jump.
            GeometryReader { geo in
                let w = max(6, geo.size.width * min(value, 100) / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(Color.usageStatus(value).gradient)
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(.white.opacity(0.28))
                                .frame(height: 3)
                                .padding(.horizontal, 3)
                                .padding(.top, 1)
                        }
                        .frame(width: w)
                        .shadow(color: Color.usageStatus(value).opacity(0.55), radius: 5, y: 1)
                        .animation(.spring(response: 0.65, dampingFraction: 0.82), value: value)
                }
            }
            .frame(height: 10)
        }
    }
}

struct SettingsPane: View {
    @EnvironmentObject var state: AppState
    @State private var checkingUpdate = false
    @State private var checkedUpToDate = false
    @AppStorage("startHour") private var startHour = 23
    @AppStorage("endHour") private var endHour = 7
    @AppStorage("fiveHourCeiling") private var fiveHourCeiling = 85.0
    @AppStorage("weeklyCeiling") private var weeklyCeiling = 90.0
    @AppStorage("resumePaceMinutes") private var resumePaceMinutes = 10.0
    @AppStorage("aroundTheClock") private var aroundTheClock = false
    @AppStorage("uiResume") private var uiResume = true
    @AppStorage("menuBarUsage") private var menuBarUsage = true
    @AppStorage(AlertSettings.burnHotKey) private var alertBurnHot = true
    @AppStorage(AlertSettings.runOutKey) private var alertRunOut = true
    @AppStorage(AlertSettings.sensitivityKey) private var alertSensitivity = BurnSensitivity.balanced.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var wakeScheduled = PowerManager.currentWakeSchedule() != nil
    // AXIsProcessTrusted() is only re-read on render, so poll while the
    // pane is open — the warning clears within seconds of granting.
    @State private var hasAccessibility = UIResumer.hasAccessibilityPermission
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Claude and ChatGPT retired the 5-hour window; its controls only make
    /// sense on a plan that still reports one.
    private var hasFiveHourWindow: Bool { state.usage?.fiveHour != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.m) {
            HStack {
                Text("Watch from").font(.caption)
                HourStepper(hour: $startHour, label: "Watch from")
                Spacer()
                Text("I'm back at").font(.caption)
                HourStepper(hour: $endHour, label: "I'm back at")
            }
            if hasFiveHourWindow {
                Text("Nothing starts after \(((endHour - 5) + 24) % 24):00, so your 5-hour window is fresh when you sit down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Resume around the clock", isOn: $aroundTheClock)
                .font(.caption)
                .toggleStyle(.checkbox)
            Text("Resumes whenever there's budget, not just at night, and keeps your Mac awake so it's ready the moment your limit resets. Best when you're plugged in. Ignores the hours above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text("Nightly wake").font(.caption)
                Spacer()
                if wakeScheduled {
                    Label("scheduled", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Button("Remove") {
                        if PowerManager.cancelNightlyWake() { wakeScheduled = false }
                    }.controlSize(.small)
                } else {
                    Button("Wake at \(startHour):00…") {
                        if PowerManager.scheduleNightlyWake(hour: startHour) { wakeScheduled = true }
                    }.controlSize(.small)
                }
            }
            Text("Night Conductor keeps your Mac awake during the watch by itself. Schedule a wake only if your Mac fully sleeps before then (asks for your password once). It can wake your Mac from sleep, but it cannot turn on a Mac that is shut down.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasFiveHourWindow {
                HStack(spacing: Design.l) {
                    Text("5h: stop at \(Int(fiveHourCeiling))% used")
                        .font(.caption).frame(width: 118, alignment: .leading)
                    NightSlider(value: $fiveHourCeiling, range: 50...100, step: 5,
                                label: "5-hour stop point", valueText: "\(Int(fiveHourCeiling))% used")
                }
            }
            HStack(spacing: Design.l) {
                Text("Stop at \(Int(weeklyCeiling))% used")
                    .font(.caption).frame(width: 118, alignment: .leading)
                NightSlider(value: $weeklyCeiling, range: 50...100, step: 5,
                            label: "Weekly stop point", valueText: "\(Int(weeklyCeiling))% used")
            }
            HStack(spacing: Design.l) {
                Text("Resume pace \(Int(resumePaceMinutes))m")
                    .font(.caption).frame(width: 118, alignment: .leading)
                NightSlider(value: $resumePaceMinutes, range: 5...20, step: 1,
                            label: "Resume pace", valueText: "every \(Int(resumePaceMinutes)) minutes")
            }
            Text("How often the watch attempts a resume overnight. Higher spreads them out more.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Show Claude usage in menu bar", isOn: $menuBarUsage)
                .font(.caption)
                .toggleStyle(.checkbox)
            Divider()
            Text("Alerts").font(.caption).bold()
            Toggle("Tell me when I'm burning faster than usual", isOn: $alertBurnHot)
                .font(.caption)
                .toggleStyle(.checkbox)
            if alertBurnHot {
                SensitivityPicker(selection: Binding(
                    get: { BurnSensitivity(rawValue: alertSensitivity) ?? .balanced },
                    set: { alertSensitivity = $0.rawValue }
                ))
                .padding(.leading, 18)
                Text((BurnSensitivity(rawValue: alertSensitivity) ?? .balanced).explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Warn me if I'll run out before a reset", isOn: $alertRunOut)
                .font(.caption)
                .toggleStyle(.checkbox)
            Text("Covers every budget above. Each warning is sent once, then stays quiet: run-out once per week, burning fast at most every 3 hours.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .font(.caption)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Divider()
            Toggle("Resume inside Conductor", isOn: $uiResume)
                .font(.caption)
                .toggleStyle(.checkbox)
            if uiResume {
                if hasAccessibility {
                    Text("Presses Conductor's own Retry button, so the chat stays in sync. Falls back to a headless resume if that fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: Design.s) {
                        Text("Needs Accessibility access to press Conductor's Retry button.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Open Accessibility Settings…") {
                            UIResumer.openAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
            Divider().opacity(0.4)
            HStack {
                if !state.isScreenshot {  // the offscreen render has no bundle version
                    Text("Version \(UpdateChecker.currentVersion)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(checkingUpdate ? "Checking…" : "Check for updates") {
                    checkingUpdate = true
                    checkedUpToDate = false
                    Task {
                        await state.checkForUpdates(force: true)
                        checkingUpdate = false
                        checkedUpToDate = state.update == nil
                    }
                }
                .controlSize(.small)
                .disabled(checkingUpdate)
            }
            if let update = state.update, let url = URL(string: UpdateChecker.safeReleaseURL(update.url)) {
                HStack(spacing: Design.s) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                    Text("Update available: \(update.version)").font(.caption)
                    Spacer()
                    Link("Download", destination: url).controlSize(.small)
                }
            } else if checkedUpToDate {
                Text("You're on the latest version.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider().opacity(0.4)
            AboutSection()
        }
        .glassCard()
        .onReceive(permissionTimer) { _ in
            hasAccessibility = UIResumer.hasAccessibilityPermission
        }
    }
}
