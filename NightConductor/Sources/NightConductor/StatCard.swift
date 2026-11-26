import AppKit
import SwiftUI

/// A shareable "My AI week" card: each subscription's share of its weekly
/// allowance, on the night sky. Rendered to an image the user can post.
/// Only numbers and plan names: no session titles, nothing from prompts.
struct StatCard: View {
    let providers: [ProviderUsage]
    var asOf: Date = Date()

    /// Readings we actually have. A window that reset since its last reading
    /// is unknown, so it's left off rather than shown as 0%.
    private var shown: [ProviderUsage] { providers.filter { !$0.isResetSinceReading } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            NightSkyView(armed: true, animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.stars.fill").foregroundStyle(.white)
                    Text("Night Conductor").font(.system(.headline, design: .serif))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(asOf.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.callout).foregroundStyle(.white.opacity(0.6))
                }
                Text("My AI week")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 14).padding(.bottom, 16)
                if shown.isEmpty {
                    Text("No usage readings yet").font(.title3).foregroundStyle(.white.opacity(0.8))
                } else {
                    VStack(spacing: 16) {
                        ForEach(shown) { StatCardRow(usage: $0) }
                    }
                }
                Spacer(minLength: 12)
                Text("github.com/jkkorn/Night-Conductor")
                    .font(.callout).foregroundStyle(.white.opacity(0.5))
            }
            .padding(28)
        }
        .frame(width: 640, height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .environment(\.colorScheme, .dark)
        .environment(\.isStillRender, true)   // bars at their value, no entrance
    }
}

private struct StatCardRow: View {
    let usage: ProviderUsage

    /// The app icon drawn into a plain bitmap first. Handing ImageRenderer the
    /// system's layered icon washes out the entire card.
    static func flatIcon(_ provider: ProviderID, points: CGFloat) -> CGImage? {
        guard let icon = ProviderBrand.icon(provider) else { return nil }
        let pixels = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    var body: some View {
        HStack(spacing: 14) {
            if let icon = Self.flatIcon(usage.provider, points: 30) {
                Image(decorative: icon, scale: 2).resizable().frame(width: 30, height: 30)
            } else {
                ProviderIcon(provider: usage.provider, size: 30)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(usage.provider.displayName).font(.title3).bold().foregroundStyle(.white)
                    if let plan = usage.plan {
                        Text(plan).font(.callout).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Text("\(Int(usage.weekly.utilization.rounded()))%")
                        .font(.system(.title2, design: .rounded)).bold().monospacedDigit()
                        .foregroundStyle(.white)
                }
                StatCardBar(value: usage.weekly.utilization, tint: ProviderBrand.accent(usage.provider))
            }
        }
    }
}

/// A flat bar for the still image. (GlowBar's blur shadow washes out the
/// whole picture when ImageRenderer flattens it.)
private struct StatCardBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(7, geo.size.width * min(max(value, 0), 100) / 100))
            }
        }
        .frame(height: 7)
    }
}

@MainActor
enum StatCardExporter {
    @discardableResult
    static func render(providers: [ProviderUsage], asOf: Date = Date(), to url: URL) -> Bool {
        let renderer = ImageRenderer(content: StatCard(providers: providers, asOf: asOf))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Render this week's real usage to ~/Downloads and reveal it.
    static func share(providers: [ProviderUsage]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/NightConductor-my-ai-week.png")
        if render(providers: providers, to: url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
