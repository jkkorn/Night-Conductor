import AppKit
import SwiftUI

/// One wording for every percentage in the app: always "used", the way
/// Claude's own usage page says it. Never "left" or a bare number.
enum UsageWording {
    static func used(_ percent: Double) -> String { "\(Int(percent.rounded()))% used" }
}

/// Where a provider's week is heading, said as one plain sentence.
/// Always paired with an icon, so it never relies on color alone.
enum PaceStatus: Equatable {
    case burningHot
    case runsOut(Date)
    case ahead
    case close
    case onPace
    case stale(Date)
    case resetSinceReading
    case unknown

    static let aheadMargin = 10.0

    static func of(_ usage: ProviderUsage, _ a: BurnAssessment, now: Date = Date()) -> PaceStatus {
        if usage.isResetSinceReading { return .resetSinceReading }
        // An old reading can't support a forecast; say it's old instead.
        if now.timeIntervalSince(usage.readAt) > UsageSummary.staleAfter { return .stale(usage.readAt) }
        if a.isBurningHot { return .burningHot }
        if let runOut = a.runsOutAt { return .runsOut(runOut) }
        guard let even = a.evenPacePercent else { return .unknown }
        let used = usage.weekly.utilization
        if used > even + aheadMargin { return .ahead }
        return used > even ? .close : .onPace
    }

    /// "use it all by Wednesday at 15:00, about 2 days before it resets".
    /// Shared by the card and the run-out notification so they always agree.
    static func runOutPhrase(_ runOut: Date, resets: Date?) -> String {
        let when = "\(runOut.formatted(.dateTime.weekday(.wide))) at \(runOut.formatted(date: .omitted, time: .shortened))"
        guard let resets else { return "use it all by \(when)" }
        let gap = resets.timeIntervalSince(runOut)
        let early = gap >= 36 * 3600
            ? "about \(Int((gap / 86_400).rounded())) days"
            : "about \(max(1, Int((gap / 3600).rounded()))) hours"
        return "use it all by \(when), \(early) before it resets"
    }

    func sentence(usage: ProviderUsage, assessment a: BurnAssessment, now: Date = Date()) -> String {
        let reset = usage.weekly.resetsAt.map { Self.possessiveDay($0, now: now) + " reset" } ?? "the reset"
        switch self {
        case .onPace:
            return "On track. You should reach \(reset) with room to spare."
        case .ahead:
            return "Using it faster than the week is passing. Ease off a little to reach \(reset)."
        case .runsOut(let date):
            return "At this pace you\u{2019}ll \(Self.runOutPhrase(date, resets: usage.weekly.resetsAt))."
        case .close:
            return "On track, but close. At this pace you\u{2019}ll use nearly all of it by \(reset)."
        case .burningHot:
            let recent = a.recentRate.map { "\(Int($0.rounded()))% used in the last hour" } ?? "a lot used in the last hour"
            let multiple = a.usualRate.flatMap { $0 > 0 ? ", about \(Int(((a.recentRate ?? 0) / $0).rounded()))x your usual" : nil } ?? ""
            return "Heavy use right now: \(recent)\(multiple)."
        case .stale(let readAt):
            return "Last reading \(readAt.formatted(.dateTime.weekday(.wide))) at "
                + "\(readAt.formatted(date: .omitted, time: .shortened)). Open \(usage.source) to refresh."
        case .resetSinceReading:
            return "Your week reset since \(usage.source) last checked. Open \(usage.source) to refresh."
        case .unknown:
            return "Learning your pace. Check back in a few hours."
        }
    }

    /// "today’s", "tomorrow’s" or "Friday’s".
    static func possessiveDay(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today\u{2019}s" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow\u{2019}s" }
        return date.formatted(.dateTime.weekday(.wide)) + "\u{2019}s"
    }

    var symbol: String {
        switch self {
        case .burningHot: return "flame.fill"
        case .runsOut: return "exclamationmark.triangle.fill"
        case .ahead: return "hare.fill"
        case .close: return "gauge.with.dots.needle.67percent"
        case .onPace: return "checkmark.circle.fill"
        case .resetSinceReading: return "arrow.counterclockwise"
        case .stale: return "clock.badge.questionmark"
        case .unknown: return "ellipsis.circle"
        }
    }

    /// nil = not a warning (the bar keeps the provider's brand color).
    var warningTint: Color? {
        switch self {
        case .burningHot, .runsOut: return .red
        case .ahead: return .orange
        default: return nil
        }
    }
}

/// Each provider looks like itself: its real app icon (borrowed from the copy
/// installed on this Mac, so no logo artwork ships in this repo) and its
/// brand color.
@MainActor
enum ProviderBrand {
    private static var cache: [ProviderID: NSImage] = [:]

    static func appPaths(_ provider: ProviderID) -> [String] {
        let names: [String]
        switch provider {
        case .claude: names = ["Claude.app"]
        case .chatgpt: names = ["ChatGPT.app", "Codex.app"]
        case .grok: names = ["Grok Bot.app", "Grok.app"]
        }
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        return roots.flatMap { root in names.map { "\(root)/\($0)" } }
    }

    static func icon(_ provider: ProviderID) -> NSImage? {
        if let hit = cache[provider] { return hit }
        guard let path = appPaths(provider).first(where: { FileManager.default.fileExists(atPath: $0) })
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[provider] = image
        return image
    }

    static func accent(_ provider: ProviderID) -> Color {
        switch provider {
        case .claude: return Color(red: 0.851, green: 0.467, blue: 0.341)   // Claude's terracotta
        case .chatgpt: return Color(red: 0.063, green: 0.639, blue: 0.498)  // ChatGPT green
        case .grok: return Color(white: 0.62)   // Grok is monochrome; a mid grey so the bar never reads as empty
        }
    }
}

struct ProviderIcon: View {
    let provider: ProviderID
    var size: CGFloat = 24

    var body: some View {
        if let image = ProviderBrand.icon(provider) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: provider.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(ProviderBrand.accent(provider).gradient, in: .rect(cornerRadius: size * 0.25))
                .accessibilityHidden(true)
        }
    }
}

/// "Your usage": a one-line summary, then one row per subscription. Accounts
/// that are fine collapse to a single line (click to open); anything that
/// needs attention stays open. Common path first, detail one level deeper.
struct BudgetsSection: View {
    @EnvironmentObject var state: AppState
    @State private var opened: Set<ProviderID> = []

    private var rows: [UsageSummary.Row] {
        state.providers.map { ($0, state.assessments[$0.provider] ?? .unknown) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.m) {
            Text("Your usage").font(.headline)
            UsageSummaryBanner(rows: rows)
                .revealOnAppear(index: 0)
            ForEach(Array(rows.enumerated()), id: \.element.usage.provider) { index, row in
                let status = PaceStatus.of(row.usage, row.assessment)
                let needsAttention = UsageSummary.urgency(status) >= 2 || status.isInformational
                    || UsageSummary.suggestsFreeReset(row.usage)
                if needsAttention || opened.contains(row.usage.provider) {
                    ProviderBudgetRow(usage: row.usage, assessment: row.assessment,
                                      extras: row.usage.provider == .claude ? claudeExtras : [],
                                      onCollapse: needsAttention ? nil : { toggle(row.usage.provider) })
                        .revealOnAppear(index: index + 1)
                } else {
                    CompactBudgetRow(usage: row.usage) { toggle(row.usage.provider) }
                        .revealOnAppear(index: index + 1)
                }
            }
            if !state.otherAITools.isEmpty {
                Text("Also on this Mac: \(state.otherAITools.joined(separator: ", ")). They don't keep a usage reading we can see.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggle(_ provider: ProviderID) {
        // No animated height change: it can dismiss a MenuBarExtra window.
        if opened.contains(provider) { opened.remove(provider) } else { opened.insert(provider) }
    }

    /// Claude's sub-limits: a model-scoped weekly cap (Fable), and the 5-hour
    /// window if a plan still has one.
    private var claudeExtras: [(String, UsageWindow)] {
        var extras: [(String, UsageWindow)] = []
        if let scoped = state.usage?.scopedWeekly { extras.append((scoped.modelName, scoped.window)) }
        if let fiveHour = state.usage?.fiveHour { extras.append(("5-hour window", fiveHour)) }
        return extras
    }
}

extension PaceStatus {
    /// Not a warning, but worth reading in full (old or reset readings).
    var isInformational: Bool {
        switch self {
        case .stale, .resetSinceReading: return true
        default: return false
        }
    }
}

/// Laid out like Claude's own usage page: who and which plan, one sentence
/// on where the week is heading, then "This week · X% used", the bar and
/// when it resets.
struct ProviderBudgetRow: View {
    let usage: ProviderUsage
    let assessment: BurnAssessment
    var extras: [(String, UsageWindow)] = []
    var onCollapse: (() -> Void)? = nil
    var now = Date()

    private var status: PaceStatus { .of(usage, assessment, now: now) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isStillRender) private var isStillRender
    private var pct: Double { usage.weekly.utilization }
    private var barTint: Color { status.warningTint ?? ProviderBrand.accent(usage.provider) }
    private var isStale: Bool { if case .stale = status { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.m) {
            HStack(alignment: .firstTextBaseline, spacing: Design.m) {
                ProviderIcon(provider: usage.provider)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Text(usage.provider.displayName).font(.headline)
                if let plan = usage.plan {
                    Text(plan).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Design.s)
                if let source = sourceNote {
                    Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let onCollapse {
                    Button("Hide details", systemImage: "chevron.down", action: onCollapse)
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Label {
                Text(status.sentence(usage: usage, assessment: assessment, now: now))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.warningTint ?? .secondary)
                    // The one ambient motion in the app, and only while you're
                    // burning fast: a slow pulse that asks for attention.
                    .symbolEffect(.pulse, options: .repeating,
                                  isActive: status == .burningHot && !reduceMotion && !isStillRender)
            }
            .font(.callout)

            Group {
                LimitRow(title: "This week", window: usage.weekly, tint: barTint, height: 6, showsReset: true)
                ForEach(extras, id: \.0) { name, window in
                    LimitRow(title: name, window: window, tint: ProviderBrand.accent(usage.provider), height: 4,
                             showsReset: UsageSummary.showsOwnReset(window.resetsAt, weekly: usage.weekly.resetsAt))
                }
            }
            .opacity(isStale ? 0.55 : 1)

            if UsageSummary.suggestsFreeReset(usage, now: now) {
                Link(destination: UsageSummary.claudeUsagePage) {
                    Label("Have a free limit reset? Open Claude usage", systemImage: "arrow.up.forward.app")
                        .font(.callout)
                }
                .help("Claude's free resets live on claude.ai. Night Conductor can't see or use them for you.")
            }
        }
        .glassCard(tint: status.warningTint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Where the number came from, for readings taken from another app's cache.
    private var sourceNote: String? {
        usage.provider == .claude ? nil : "via \(usage.source)"
    }

    private var accessibilitySummary: String {
        var text = "\(usage.provider.displayName): \(UsageWording.used(pct)) this week. "
            + status.sentence(usage: usage, assessment: assessment, now: now)
        if let resets = usage.weekly.resetsAt {
            text += " Resets \(resets.formatted(.dateTime.weekday(.wide).hour().minute()))."
        }
        return text
    }
}

/// "This week                15% used" / bar / "Resets Friday 2:00 AM".
private struct LimitRow: View {
    let title: String
    let window: UsageWindow
    let tint: Color
    var height: CGFloat
    var showsReset: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Design.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(height > 5 ? .subheadline : .caption)
                Spacer()
                UsedFigure(percent: window.utilization, font: height > 5 ? .title3 : .callout)
            }
            GlowBar(value: window.utilization, tint: tint, height: height)
            if showsReset, let resets = window.resetsAt {
                Text("Resets \(resets.formatted(.dateTime.weekday(.wide).hour().minute()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Three-way "how touchy are burn alerts" control. Built from plain buttons
/// (like HourStepper) because AppKit-backed pickers trigger layout cycles in
/// this popover's hosting context.
struct SensitivityPicker: View {
    @Binding var selection: BurnSensitivity

    var body: some View {
        HStack(spacing: 2) {
            ForEach(BurnSensitivity.allCases) { option in
                let selected = option == selection
                Button(option.label) {
                    withAnimation(.snappy(duration: 0.18)) { selection = option }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .bold(selected)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Design.s)
                .background(selected ? AnyShapeStyle(Color.indigo.gradient) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Burn alert sensitivity")
    }
}
