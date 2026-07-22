import AppKit

/// Resolves a source app's bundle ID to its human name and Finder icon, cached
/// — NSWorkspace disk lookups aren't free and the same few apps recur down
/// every list. Shared by the clip list, the QuickPanel, and the preview header.
@MainActor
final class AppNameResolver {
    static let shared = AppNameResolver()

    private struct Entry {
        var name: String
        var icon: NSImage?
        var resolvedAt: Date
        /// Misses retry: an app installed a minute from now must not show a
        /// generic glyph for the rest of the process lifetime (Maccy G12).
        var installed: Bool
    }
    private var cache: [String: Entry] = [:]
    private static let missRetryInterval: TimeInterval = 3600

    /// "CleanShot X" for its bundle ID; capitalized bundle tail when the app
    /// isn't installed; nil for a nil bundle ID.
    func displayName(for bundleID: String?) -> String? { entry(for: bundleID)?.name }

    /// The app's Finder icon, or nil when it isn't installed (callers fall
    /// back to a generic glyph).
    func icon(for bundleID: String?) -> NSImage? { entry(for: bundleID)?.icon }

    private func entry(for bundleID: String?) -> (name: String, icon: NSImage?)? {
        guard let bundleID else { return nil }
        if let hit = cache[bundleID],
           hit.installed || Date().timeIntervalSince(hit.resolvedAt) < Self.missRetryInterval {
            return (hit.name, hit.icon)
        }
        let made: Entry
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            made = Entry(name: name, icon: NSWorkspace.shared.icon(forFile: url.path),
                         resolvedAt: Date(), installed: true)
        } else {
            let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            made = Entry(name: tail.prefix(1).uppercased() + tail.dropFirst(), icon: nil,
                         resolvedAt: Date(), installed: false)
        }
        cache[bundleID] = made
        return (made.name, made.icon)
    }
}
