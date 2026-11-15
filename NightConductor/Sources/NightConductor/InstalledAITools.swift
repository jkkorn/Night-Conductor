import Foundation

/// AI tools present on this Mac whose limits we can't read (they keep no
/// usage reading on disk), so the popover can say so honestly instead of
/// pretending they don't exist. Presence checks only; nothing is opened.
enum InstalledAITools {
    /// App bundle name → display name. Tools with a reader (Claude, ChatGPT
    /// via Codex, Grok Bot) are deliberately absent.
    static let catalog: [(bundle: String, name: String)] = [
        ("Cursor.app", "Cursor"), ("Windsurf.app", "Windsurf"),
        ("Antigravity.app", "Antigravity"), ("Gemini.app", "Gemini"),
        ("Perplexity.app", "Perplexity"), ("Copilot.app", "Copilot"),
        ("Zed.app", "Zed"), ("LM Studio.app", "LM Studio"), ("Ollama.app", "Ollama"),
    ]

    static func detectWithoutUsage(fileManager: FileManager = .default) -> [String] {
        let roots = ["/Applications", fileManager.homeDirectoryForCurrentUser.path + "/Applications"]
        return catalog.compactMap { entry in
            roots.contains { fileManager.fileExists(atPath: "\($0)/\(entry.bundle)") } ? entry.name : nil
        }
    }
}
