import Foundation
import AppKit
import Testing
@testable import ClipMateCore

/// End-to-end regression for the blue "this row IS your clipboard" highlight:
/// ClipboardProbe over the REAL SystemPasteboard. The Explorer copies a
/// selected clip with the ownership stamp, so the probe MUST be able to hash
/// an own-write — the stamp is capture plumbing, not a privacy marker.
///
/// SAFETY: private, uniquely-named pasteboards only — never NSPasteboard.general.
@Suite("ClipboardProbe")
struct ClipboardProbeTests {

    private func privatePasteboard(_ name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.clipmateclone.tests.\(name)"))
        pb.clearContents()
        return pb
    }

    @MainActor
    @Test("an own-write hashes and matches — the highlight can light after our own copy")
    func ownWriteMatches() throws {
        let pb = privatePasteboard("probe-own-\(UUID().uuidString)")
        pb.declareTypes(
            [NSPasteboard.PasteboardType(PasteboardMarkers.ownership),
             NSPasteboard.PasteboardType(SupportedTypes.plainText)],
            owner: nil)
        pb.setString("we paste this back", forType: NSPasteboard.PasteboardType(SupportedTypes.plainText))

        let probe = ClipboardProbe(pasteboard: SystemPasteboard(pb))

        let expected = ContentHasher.hash(Data("we paste this back".utf8))
        #expect(probe.currentHash() == expected,
                "after ClipMate's own clipboard write, the probe must still fingerprint the content")
    }

    @MainActor
    @Test("SECURITY: a concealed clip never produces a hash")
    func concealedNeverMatches() throws {
        let pb = privatePasteboard("probe-concealed-\(UUID().uuidString)")
        pb.declareTypes(
            [NSPasteboard.PasteboardType(PasteboardMarkers.concealed),
             NSPasteboard.PasteboardType(SupportedTypes.plainText)],
            owner: nil)
        pb.setString("hunter2", forType: NSPasteboard.PasteboardType(SupportedTypes.plainText))

        let probe = ClipboardProbe(pasteboard: SystemPasteboard(pb))

        #expect(probe.currentHash() == nil,
                "a concealed copy must never light a row blue — we don't hold it and must not claim to")
    }
}
