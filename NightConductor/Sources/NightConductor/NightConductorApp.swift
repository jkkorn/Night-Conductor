import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let flagIndex = args.firstIndex(of: "--render-screenshot"), args.count > flagIndex + 1 {
            var stateName = "default"
            if let s = args.firstIndex(of: "--state"), args.count > s + 1 { stateName = args[s + 1] }
            var hour = 23.0
            if let h = args.firstIndex(of: "--hour"), args.count > h + 1 { hour = Double(args[h + 1]) ?? 23 }
            MainActor.assumeIsolated {
                Screenshotter.render(
                    to: args[flagIndex + 1],
                    showSettings: args.contains("--settings"),
                    state: stateName,
                    hour: hour,
                    light: args.contains("--light")
                )
            }
            return
        }
        if let flagIndex = args.firstIndex(of: "--render-menubar"), args.count > flagIndex + 1 {
            MainActor.assumeIsolated { Screenshotter.renderMenuBar(to: args[flagIndex + 1]) }
            return
        }
        if let flagIndex = args.firstIndex(of: "--render-statcard"), args.count > flagIndex + 2 {
            let count = Int(args[flagIndex + 1]) ?? 12
            MainActor.assumeIsolated {
                NightSkyView.hourOverride = 23
                _ = StatCardExporter.render(count: count, to: URL(fileURLWithPath: args[flagIndex + 2]))
            }
            return
        }
        if args.contains("--usage") {
            // Local readers only (no network, no credentials): proof of what
            // the budgets section will show for ChatGPT and Grok.
            let now = Date()
            let log = UsageSampleLog.load()
            for reading in [CodexUsageReader.read(), GrokBotUsageReader.read()].compactMap({ $0 }) {
                let shown = reading.normalized(now: now)
                let a = BurnForecast.assess(usage: shown, samples: log.samples(for: shown.provider), now: now)
                print("\(shown.provider.displayName) [\(shown.source)\(shown.plan.map { ", \($0)" } ?? "")]: "
                      + "\(UsageWording.used(shown.weekly.utilization)) this week, resets \(shown.weekly.resetsAt.map { "\($0)" } ?? "n/a"), "
                      + "read \(reading.readAt), status: \(PaceStatus.of(shown, a).sentence(usage: shown, assessment: a))")
            }
            print("Other AI tools without usage data: \(InstalledAITools.detectWithoutUsage())")
            return
        }
        if args.contains("--scan") {
            let conductor = (try? ConductorDB.findStalledSessions()) ?? []
            let claude = ClaudeDesktopDB.findStalledSessions()
            print("Conductor stalled: \(conductor.count)")
            for s in conductor { print("  - \(s.title) [\(s.kind.shortLabel)] @ \(s.workspaceName)") }
            print("Claude Desktop stalled: \(claude.count)")
            for s in claude { print("  - \(s.title) [\(s.kind.shortLabel)] @ \(s.workspaceName)") }
            let cc = ClaudeCodeDB.findStalledSessions()
            print("Claude Code (terminal) stalled: \(cc.count)")
            for s in cc { print("  - \(s.title) [\(s.kind.shortLabel)] @ \(s.workspaceName)") }
            return
        }
        NightConductorApp.main()
    }
}

struct NightConductorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item: a ring gauge that fills with your live Claude usage
/// (the weekly budget now that the 5-hour window is gone; the 5-hour one if a
/// plan still has it), so it reads as a consumption meter, not a weather glyph. Dims when paused. Falls back
/// to the moon when usage display is turned off.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @AppStorage("armed") private var armed = true
    @AppStorage("menuBarUsage") private var menuBarUsage = true

    var body: some View {
        if menuBarUsage, let usage = state.usage {
            // Show Claude, unless another account needs attention right now:
            // the menu bar is what you see all day, so it must not hide a problem.
            let rows = state.providers.map { ($0, state.assessments[$0.provider] ?? .unknown) }
            let urgent = UsageSummary.mostUrgent(rows)
            let pct = urgent?.weekly.utilization ?? (usage.fiveHour ?? usage.sevenDay).utilization
            let who = urgent?.provider.displayName ?? "Claude"
            let tint = urgent.map { PaceStatus.of($0, state.assessments[$0.provider] ?? .unknown).warningTint } ?? nil
            HStack(spacing: 3) {
                if let urgent {
                    ProviderIcon(provider: urgent.provider, size: 14)
                }
                UsageRing(value: pct, armed: armed, tint: tint)
                Text("\(Int(pct))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(armed ? .primary : .secondary)
            }
            // Too tight for the word in the menu bar itself; say it in full here.
            .help("\(who): \(UsageWording.used(pct)) this week")
            .accessibilityLabel("\(who): \(UsageWording.used(pct)) this week")
        } else {
            Image(systemName: armed ? "moon.stars.fill" : "moon.zzz")
        }
    }
}
