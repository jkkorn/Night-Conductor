import AppKit
import SwiftUI

/// A shareable "this week" card — a big number on the living night sky.
/// Rendered to an image the user can drop into a post.
struct StatCard: View {
    let weekCount: Int

    var body: some View {
        ZStack(alignment: .leading) {
            NightSkyView(armed: true, animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.stars.fill").font(.title3).foregroundStyle(.white)
                    Text("Night Conductor")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                Spacer()
                Text("\(weekCount)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                Text(weekCount == 1
                     ? "session resumed while I slept this week"
                     : "sessions resumed while I slept this week")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("github.com/jkkorn/Night-Conductor")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(28)
        }
        .frame(width: 640, height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
enum StatCardExporter {
    @discardableResult
    static func render(count: Int, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: StatCard(weekCount: count))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Render the user's real weekly count to ~/Downloads and reveal it.
    static func share() {
        let count = ResumeHistory.weekCount()
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/NightConductor-this-week.png")
        if render(count: count, to: url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
