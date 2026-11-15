import Foundation

/// Multi-provider budgets: read every subscription we can, keep a small
/// history, forecast each week, and raise the two alerts people asked for
/// ("burning more than usual", "will run out before reset").
extension AppState {
    /// Local readers touch other apps' files, so they run at most once a minute.
    static let localProviderInterval: TimeInterval = 60

    func refreshBudgets(now: Date = Date()) async {
        guard !isScreenshot else { return }
        if now.timeIntervalSince(lastLocalProviderRead ?? .distantPast) >= Self.localProviderInterval {
            lastLocalProviderRead = now
            let (local, others) = await Task.detached(priority: .utility) {
                ([CodexUsageReader.read(), GrokBotUsageReader.read()].compactMap { $0 },
                 InstalledAITools.detectWithoutUsage())
            }.value
            cachedLocalProviders = local
            otherAITools = others
        }

        let raw = (usage.map { [ProviderUsage.claude(from: $0)] } ?? []) + cachedLocalProviders
        var log = sampleLog
        for reading in raw where (reading.weekly.resetsAt ?? .distantFuture) > now {
            log = log.appending(UsageSample(at: reading.readAt, percent: reading.weekly.utilization,
                                            resetsAt: reading.weekly.resetsAt), for: reading.provider)
        }
        if log != sampleLog {
            sampleLog = log
            try? log.save()
        }

        let settings = AlertSettings.fromDefaults()
        let threshold = settings.sensitivity.threshold
        providers = raw.map { $0.normalized(now: now) }
        assessments = Dictionary(uniqueKeysWithValues: providers.map {
            ($0.provider, BurnForecast.assess(usage: $0, samples: log.samples(for: $0.provider),
                                              now: now, threshold: threshold))
        })
        raiseAlerts(settings: settings, now: now)
    }

    private func raiseAlerts(settings: AlertSettings, now: Date) {
        guard settings.burnHot || settings.runOut else { return }
        let candidates = providers.flatMap { usage in
            UsageAlerts.candidates(usage: usage, assessment: assessments[usage.provider] ?? .unknown,
                                   settings: settings, now: now)
        }
        let sent = UsageAlerts.loadSent()
        let fresh = UsageAlerts.unsent(candidates, sent: sent, now: now)
        guard !fresh.isEmpty else { return }
        UsageAlerts.saveSent(UsageAlerts.marking(fresh, sent: sent, now: now))
        for alert in fresh {
            UsageAlerts.post(alert)
            log("🔔 \(alert.title)")
        }
    }
}
