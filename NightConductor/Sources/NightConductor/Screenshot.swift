import AppKit
import SwiftUI

/// Hidden CLI mode that renders the popover to a PNG for docs/marketing:
///   NightConductor --render-screenshot out.png [--settings]
/// Uses representative demo data so real session titles never ship.
@MainActor
enum Screenshotter {
    static func render(to path: String, showSettings: Bool, state stateName: String = "default", hour: Double = 23) {
        // ImageRenderer can't draw NSView-backed controls (Toggle, Stepper,
        // Slider), so render in a real off-to-the-side window and snapshot
        // the view hierarchy instead — that draws everything.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        app.finishLaunching()

        NightSkyView.hourOverride = hour // docs default to night (23)
        // demoState writes the real `armed` pref (the views read it through
        // @AppStorage). Put the user's own value back when we're done, so a
        // render can never silently disarm the watch (security audit L5).
        let previousArmed = UserDefaults.standard.object(forKey: "armed")
        defer { UserDefaults.standard.set(previousArmed, forKey: "armed") }
        let state = demoState(stateName)
        let root = MenuView(showSettings: showSettings, showActivity: stateName == "activity")
            .environmentObject(state)
            .frame(width: 340)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(red: 0.12, green: 0.12, blue: 0.14))
            .environment(\.colorScheme, .dark)
            .environment(\.isStillRender, true)
        renderHosting(AnyView(root), to: path)
    }

    /// Render the menu-bar label at a few usage levels on a dark strip, to
    /// verify it reads as a consumption gauge.
    static func renderMenuBar(to path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        app.finishLaunching()
        let strip = HStack(spacing: 22) {
            ForEach([18.0, 52.0, 91.0], id: \.self) { v in
                HStack(spacing: 3) {
                    UsageRing(value: v)
                    Text("\(Int(v))%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 24)
        .background(Color(red: 0.13, green: 0.13, blue: 0.15))
        .environment(\.colorScheme, .dark)
        renderHosting(strip.fixedSize(), to: path)
    }

    private static func renderHosting(_ rootView: some View, to path: String) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 900)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.orderFrontRegardless()

        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let fitting = hosting.fittingSize
        window.setContentSize(fitting)
        hosting.frame = NSRect(origin: .zero, size: fitting)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Render at 2x so docs/marketing images are retina-crisp. An offscreen
        // window has a 1.0 backing scale, so bitmapImageRepForCachingDisplay
        // would give soft 1x output; allocate an explicit 2x rep instead.
        let scale = 2
        let bounds = hosting.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width) * scale,
            pixelsHigh: Int(bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            exit(1)
        }
        rep.size = bounds.size // points; 2x pixels gives a retina-scale image
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("encode failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
        window.orderOut(nil)
        print("Wrote \(path)")
    }

    private static func demoState(_ name: String = "default") -> AppState {
        // Per-state knobs so we can audit every visual state as a still.
        let armed = name != "paused"
        let weekly = name == "high" ? 76.0 : 29.0
        UserDefaults.standard.set(armed, forKey: "armed")

        let state = AppState(forScreenshots: true)
        state.screenshotSetup = name == "blocked" ? "blocked" : (name == "setup" ? "finish" : nil)
        let now = Date()
        state.usage = UsageSnapshot(
            fiveHour: nil, // Claude is weekly-only now
            sevenDay: UsageWindow(utilization: weekly, resetsAt: now.addingTimeInterval(1.6 * 86_400)),
            scopedWeekly: ScopedWeekly(
                modelName: "Fable",
                window: UsageWindow(utilization: 41, resetsAt: now.addingTimeInterval(3.4 * 86_400))
            ),
            plan: "Max 20x",
            fetchedAt: now
        )
        let claude = ProviderUsage.claude(from: state.usage!)
        let chatgpt = ProviderUsage(provider: .chatgpt, source: "Codex", plan: "Pro",
                                    weekly: UsageWindow(utilization: name == "high" ? 71 : 26,
                                                        resetsAt: now.addingTimeInterval(5.1 * 86_400)),
                                    readAt: now.addingTimeInterval(-120))
        let grok = ProviderUsage(provider: .grok, source: "Grok Bot", plan: "Grok Bot Plan",
                                 weekly: UsageWindow(utilization: 52, resetsAt: now.addingTimeInterval(1.8 * 86_400)),
                                 readAt: now.addingTimeInterval(-2 * 86_400))
        state.providers = [claude, chatgpt, grok]
        state.assessments = [
            .claude: BurnAssessment(evenPacePercent: 77, runsOutAt: nil, recentRate: name == "high" ? 9 : 2, usualRate: 3,
                                    isBurningHot: name == "high"),
            .chatgpt: BurnAssessment(evenPacePercent: 27,
                                     runsOutAt: name == "high" ? now.addingTimeInterval(2.2 * 86_400) : nil,
                                     recentRate: 1, usualRate: 2, isBurningHot: false),
            .grok: BurnAssessment(evenPacePercent: 74, runsOutAt: nil, recentRate: nil, usualRate: nil,
                                  isBurningHot: false),
        ]
        state.decision = name == "high"
            ? Decision(resume: false, reason: "Using the week too fast: 76% used, 1.6 days to reset", state: .holding)
            : Decision(resume: true, reason: "Room to spare: 29% used this week, 1.6 days to reset", state: .resuming)
        let base = [
            StalledSession(
                sessionID: "demo-1", claudeSessionID: "demo-1",
                title: "Refactor onboarding flow", workspacePath: "/ws/myapp/oslo",
                errorText: "You've hit your session limit · resets 1:30am",
                stalledAt: now.addingTimeInterval(-40 * 60)
            ),
            StalledSession(
                sessionID: "demo-2", claudeSessionID: "demo-2",
                title: "Fix paywall A/B variants", workspacePath: "/ws/myapp/dallas",
                errorText: "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited",
                stalledAt: now.addingTimeInterval(-25 * 60)
            ),
        ]
        switch name {
        case "empty": state.stalled = []
        case "many":
            let titles = ["Refactor onboarding flow", "Fix paywall A/B variants",
                          "Migrate auth to OAuth", "Add dark mode", "Write E2E tests",
                          "Optimize image pipeline", "Fix flaky CI", "Bump dependencies"]
            state.stalled = titles.enumerated().map { i, t in
                StalledSession(
                    sessionID: "demo-\(i)", claudeSessionID: "demo-\(i)", title: t,
                    workspacePath: "/ws/myapp/\(["oslo", "dallas", "lima", "cebu"][i % 4])",
                    errorText: i % 3 == 0
                        ? "API Error: Server is temporarily limiting requests (not your usage limit)"
                        : "You've hit your session limit · resets 1:30am",
                    stalledAt: now
                )
            }
        default: state.stalled = base
        }
        state.lastTick = now
        return state
    }
}
