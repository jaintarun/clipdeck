import Foundation

/// Fingerprints the clipboard exactly the way capture does, so the UI can tell
/// whether a given clip is what's on the system clipboard right now — the basis
/// for ClipMate's blue "this row IS your clipboard" selection.
///
/// The primary-data rules here MUST stay identical to the ones CaptureEngine
/// uses to hash a clip, or a match would never light up. They are the same code:
/// CaptureEngine.process() calls `primaryData` too.
public enum ClipboardMatcher {
    /// The primary representation's bytes for a set of supported payloads,
    /// chosen and normalized the same way capture fingerprints a clip: file URLs
    /// win, else plain text (line endings normalized for hashing only), else the
    /// largest image. nil when nothing capturable is present.
    public static func primaryData(payloads: [String: Data]) -> Data? {
        let supported = payloads.filter { SupportedTypes.all.contains($0.key) }
        guard !supported.isEmpty else { return nil }

        // Files beat text: a Finder copy carries the filenames as text too, and
        // hashing the text would make two same-named files in different folders
        // collide (mirrors CaptureEngine's AMEND-2 comment).
        let fileURLs = supported[SupportedTypes.fileURL].map { FileClip.decode($0) } ?? []
        if !fileURLs.isEmpty {
            return FileClip.encode(fileURLs)
        }
        if let textData = supported[SupportedTypes.plainText],
           let s = String(data: textData, encoding: .utf8) {
            let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
                              .replacingOccurrences(of: "\r", with: "\n")
            return Data(normalized.utf8)
        }
        return supported
            .filter { SupportedTypes.images.contains($0.key) }
            .map(\.value)
            .max(by: { $0.count < $1.count })
    }

    /// The content hash used to match a clip (`Clip.contentHash`) against the
    /// clipboard. nil when the clipboard holds nothing we'd have captured.
    public static func primaryHash(payloads: [String: Data]) -> Data? {
        primaryData(payloads: payloads).map(ContentHasher.hash)
    }
}

/// Answers "what's the fingerprint of the clipboard right now?" for the
/// Explorer's blue-selection highlight, caching by changeCount so the repeated
/// calls made on every reload don't re-hash an unchanged clipboard — a large
/// image would otherwise be hashed on the main thread on every capture.
///
/// MainActor: reads the pasteboard, which is not documented thread-safe (same
/// reasoning as CaptureEngine.detectChange).
@MainActor
public final class ClipboardProbe {
    private let pasteboard: any PasteboardReading
    private var cachedChangeCount: Int?
    private var cachedHash: Data?

    public init(pasteboard: any PasteboardReading) {
        self.pasteboard = pasteboard
    }

    /// Primary-content hash of the current clipboard, or nil if it holds nothing
    /// we'd capture (a concealed/transient copy, or unsupported content).
    public func currentHash() -> Data? {
        let changeCount = pasteboard.changeCount
        if cachedChangeCount == changeCount { return cachedHash }
        cachedChangeCount = changeCount
        cachedHash = Self.compute(pasteboard)
        return cachedHash
    }

    private static func compute(_ pasteboard: any PasteboardReading) -> Data? {
        guard let snapshot = pasteboard.snapshot() else { return nil }
        // A concealed/transient copy (password manager) must never light a row
        // blue — we don't hold it and must not claim to. Checked before reading
        // payloads, same as the capture path.
        if snapshot.types.contains(where: { PasteboardMarkers.allSkipped.contains($0) }) {
            return nil
        }
        return ClipboardMatcher.primaryHash(payloads: snapshot.payloads)
    }
}
