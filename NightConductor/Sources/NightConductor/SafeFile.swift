import Foundation

/// Bounded, symlink-aware reads for files other apps wrote. Everything read
/// through here is untrusted: callers take numbers and display strings out of
/// it, never paths or arguments.
enum SafeFile {
    /// True when `url` (symlinks resolved) sits strictly under `root`.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    static func isRegularNonSymlink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    /// The last `maxBytes` of a file (whole file if smaller).
    static func readTail(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    /// A whole file, refusing anything larger than `maxBytes`.
    static func readAll(_ url: URL, maxBytes: Int) -> Data? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= maxBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    static func clampPercent(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 0
    }
}
