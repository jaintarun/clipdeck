import Foundation
import AppKit

/// The real NSPasteboard. Deliberately dumb — all policy lives in CaptureEngine
/// so the policy is testable.
public final class SystemPasteboard: PasteboardReading, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> PasteboardSnapshot? {
        let count = pasteboard.changeCount
        let types = (pasteboard.types ?? []).map(\.rawValue)

        // Read nothing if this is concealed/transient — checking before reading
        // is the point (spec §6). Our own ownership stamp does NOT suppress the
        // read: it is capture plumbing, not a privacy marker — CaptureEngine
        // rejects own-writes by type (.rejectedOwnWrite), while ClipboardProbe
        // needs these payloads or the clipboard-match highlight can never light
        // after the app's own copy.
        if types.contains(where: { PasteboardMarkers.allSkipped.contains($0) }) {
            return PasteboardSnapshot(changeCount: count, types: types, payloads: [:])
        }

        var payloads: [String: Data] = [:]
        for type in types where SupportedTypes.all.contains(type) || type == SupportedTypes.sourceURL {
            // File URLs need the item-aware reader. Two measured reasons:
            // data(forType:) returns only the FIRST item's URL, silently
            // dropping the rest of a multi-file copy; and Finder writes
            // opaque `file:///.file/id=…` URLs whose lastPathComponent is an
            // ID, not a filename. readObjects returns every item, resolved.
            if type == SupportedTypes.fileURL {
                let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL]) ?? []
                let fileURLs = urls.filter(\.isFileURL)
                if !fileURLs.isEmpty {
                    payloads[type] = FileClip.encode(fileURLs)
                }
                continue
            }
            // The source URL rides as a `public.url` item. Read it via the
            // object reader (not data(forType:), which yields platform-specific
            // bytes) and keep only a real web URL — never a file URL, which is
            // handled above and must not leak a local path here.
            if type == SupportedTypes.sourceURL {
                let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL]) ?? []
                if let web = urls.first(where: { !$0.isFileURL }) {
                    payloads[type] = Data(web.absoluteString.utf8)
                }
                continue
            }
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) {
                payloads[type] = data
            }
        }
        return PasteboardSnapshot(changeCount: count, types: types, payloads: payloads)
    }
}
