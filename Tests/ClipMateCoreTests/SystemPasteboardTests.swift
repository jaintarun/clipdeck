import Foundation
import AppKit
import Testing
@testable import ClipMateCore

/// Exercises the REAL SystemPasteboard against a REAL NSPasteboard. Every
/// other CaptureEngine test goes through FakePasteboard, which never touches
/// the guard in SystemPasteboard.snapshot() that keeps a password manager's
/// bytes out of memory in the first place. This suite is the only place that
/// guard is actually proven.
///
/// SAFETY: never use NSPasteboard.general here — that is the user's real
/// clipboard. Every test below uses its own uniquely-named private pasteboard
/// so tests can run in parallel without clobbering each other or the user.
@Suite("SystemPasteboard")
struct SystemPasteboardTests {

    private func privatePasteboard(_ name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.clipmateclone.tests.\(name)"))
        pb.clearContents()
        return pb
    }

    @Test("SECURITY: a concealed clip's payload is never read")
    func concealedPayloadIsNeverRead() throws {
        let pb = privatePasteboard("concealed-\(UUID().uuidString)")
        pb.declareTypes(
            [NSPasteboard.PasteboardType(PasteboardMarkers.concealed),
             NSPasteboard.PasteboardType(SupportedTypes.plainText)],
            owner: nil)
        pb.setString("hunter2", forType: NSPasteboard.PasteboardType(SupportedTypes.plainText))

        let snapshot = try #require(SystemPasteboard(pb).snapshot())

        #expect(snapshot.payloads.isEmpty, "a concealed clip's bytes must never be read into memory")
    }

    @Test("POSITIVE CONTROL: plain text with no markers is read normally")
    func plainTextIsReadWhenUnmarked() throws {
        let pb = privatePasteboard("plain-\(UUID().uuidString)")
        pb.declareTypes([NSPasteboard.PasteboardType(SupportedTypes.plainText)], owner: nil)
        pb.setString("hello clipboard", forType: NSPasteboard.PasteboardType(SupportedTypes.plainText))

        let snapshot = try #require(SystemPasteboard(pb).snapshot())

        let data = try #require(snapshot.payloads[SupportedTypes.plainText])
        #expect(String(data: data, encoding: .utf8) == "hello clipboard")
    }

    @Test("resolves every url of a multi-file copy, not just the first")
    func resolvesAllFileURLs() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pb.releaseGlobally() }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("alpha.txt")
        let b = dir.appendingPathComponent("beta.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        pb.clearContents()
        pb.writeObjects([a as NSURL, b as NSURL])

        let snapshot = try #require(SystemPasteboard(pb).snapshot())
        let payload = try #require(snapshot.payloads[SupportedTypes.fileURL])

        // The naive implementation — pb.data(forType:) — returns only the
        // FIRST url (measured). If this ever passes against that, it is not
        // testing what it claims to.
        #expect(FileClip.decode(payload).map(\.lastPathComponent) == ["alpha.txt", "beta.txt"])
    }

    @Test("our own marked write IS read — the probe needs it; capture rejects it by type")
    func ownWritePayloadIsRead() throws {
        // Skipping the read here (as this code once did) starved ClipboardProbe:
        // after any of our own clipboard writes the blue "this row IS your
        // clipboard" highlight could never light. Own-writes carry no privacy
        // risk — the bytes came from our own store — and CaptureEngine.process()
        // rejects them by the type marker (.rejectedOwnWrite), not by absence
        // of payloads.
        let pb = privatePasteboard("ownership-\(UUID().uuidString)")
        pb.declareTypes(
            [NSPasteboard.PasteboardType(PasteboardMarkers.ownership),
             NSPasteboard.PasteboardType(SupportedTypes.plainText)],
            owner: nil)
        pb.setString("we just pasted this", forType: NSPasteboard.PasteboardType(SupportedTypes.plainText))

        let snapshot = try #require(SystemPasteboard(pb).snapshot())

        let data = try #require(snapshot.payloads[SupportedTypes.plainText])
        #expect(String(data: data, encoding: .utf8) == "we just pasted this")
        #expect(snapshot.types.contains(PasteboardMarkers.ownership),
                "the marker must survive in types so CaptureEngine can reject the own-write")
    }

    @Test("merges representations across multiple pasteboard items (BBEdit/Edge shape)")
    func mergesMultiItemCopy() throws {
        let pb = privatePasteboard("multiitem-\(UUID().uuidString)")
        let textItem = NSPasteboardItem()
        textItem.setString("plain words", forType: .string)
        let htmlItem = NSPasteboardItem()
        htmlItem.setData(Data("<b>rich</b>".utf8), forType: .html)
        pb.writeObjects([textItem, htmlItem])

        let snapshot = try #require(SystemPasteboard(pb).snapshot())

        #expect(snapshot.payloads[SupportedTypes.plainText]
            .flatMap { String(data: $0, encoding: .utf8) } == "plain words")
        // The naive whole-board read resolves only one item's types; the html
        // rides on item 2 and must still be captured.
        #expect(snapshot.payloads[SupportedTypes.html]
            .flatMap { String(data: $0, encoding: .utf8) } == "<b>rich</b>")
    }

    @Test("a declared type with no data behind it never blocks the others (Maccy c3c727)")
    func declaredButAbsentTypeIsSkipped() throws {
        let pb = privatePasteboard("declared-\(UUID().uuidString)")
        pb.declareTypes(
            [NSPasteboard.PasteboardType(SupportedTypes.html),      // declared, never provided
             NSPasteboard.PasteboardType(SupportedTypes.plainText)],
            owner: nil)
        pb.setString("real content", forType: NSPasteboard.PasteboardType(SupportedTypes.plainText))

        let snapshot = try #require(SystemPasteboard(pb).snapshot())

        #expect(snapshot.payloads[SupportedTypes.plainText] != nil)
        #expect(snapshot.payloads[SupportedTypes.html] == nil)
    }
}
