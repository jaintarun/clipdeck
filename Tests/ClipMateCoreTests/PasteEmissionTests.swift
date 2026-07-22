import AppKit
import Foundation
import Testing
@testable import ClipMateCore

@Suite("PasteEmission")
struct PasteEmissionTests {

    private func rep(_ uti: String, _ text: String) -> ClipRepresentation {
        ClipRepresentation(clipID: 1, utiIdentifier: uti, data: Data(text.utf8))
    }

    @Test("full fidelity passes every representation through untouched")
    func fullPassthrough() {
        let reps = [rep(SupportedTypes.plainText, "hi"), rep(SupportedTypes.rtf, "rtf-bytes")]
        #expect(PasteEmission.representations(for: reps, fidelity: .full) == reps)
    }

    @Test("plain keeps only the plain-text representation")
    func plainKeepsPlainOnly() {
        let plain = rep(SupportedTypes.plainText, "hi")
        let reps = [plain, rep(SupportedTypes.rtf, "x"), rep(SupportedTypes.html, "<b>hi</b>")]
        #expect(PasteEmission.representations(for: reps, fidelity: .plain) == [plain])
    }

    @Test("rtf-only clip synthesizes a plain-text rep via PlainTextRendering")
    func rtfOnlyRenders() throws {
        let rtfData = try #require(NSAttributedString(string: "hello rtf").rtf(
            from: NSRange(location: 0, length: 9), documentAttributes: [:]))
        let reps = [ClipRepresentation(clipID: 1, utiIdentifier: SupportedTypes.rtf, data: rtfData)]
        let out = PasteEmission.representations(for: reps, fidelity: .plain)
        #expect(out.count == 1)
        #expect(out[0].utiIdentifier == SupportedTypes.plainText)
        #expect(String(data: out[0].data, encoding: .utf8) == "hello rtf")
    }

    @Test("html-only clip synthesizes a plain-text rep via the tag stripper")
    func htmlOnlyRenders() {
        let reps = [rep(SupportedTypes.html, "<p>hello <b>html</b></p>")]
        let out = PasteEmission.representations(for: reps, fidelity: .plain)
        #expect(out.count == 1)
        #expect(out[0].utiIdentifier == SupportedTypes.plainText)
        #expect(String(data: out[0].data, encoding: .utf8)?.contains("hello html") == true)
    }

    @Test("file clips are exempt: plain emits everything (Maccy #962 guard)")
    func fileClipsExempt() {
        let reps = [rep(SupportedTypes.fileURL, "/tmp/a.txt"), rep(SupportedTypes.plainText, "a.txt")]
        #expect(PasteEmission.representations(for: reps, fidelity: .plain) == reps)
    }

    @Test("image clips are exempt: plain emits everything")
    func imageClipsExempt() {
        let reps = [ClipRepresentation(clipID: 1, utiIdentifier: SupportedTypes.png, data: Data([0xAB]))]
        #expect(PasteEmission.representations(for: reps, fidelity: .plain) == reps)
    }

    @Test("when nothing renders, plain falls back to full — never an empty write")
    func nothingRendersFallsBack() {
        // Markup-only HTML strips to nothing visible.
        let reps = [rep(SupportedTypes.html, "<div><span></span></div>")]
        #expect(PasteEmission.representations(for: reps, fidelity: .plain) == reps)
    }

    @Test("resolve: option inverts whichever default is set")
    func resolveTruthTable() {
        #expect(PasteFidelity.resolve(plainByDefault: true, optionHeld: false) == .plain)
        #expect(PasteFidelity.resolve(plainByDefault: true, optionHeld: true) == .full)
        #expect(PasteFidelity.resolve(plainByDefault: false, optionHeld: false) == .full)
        #expect(PasteFidelity.resolve(plainByDefault: false, optionHeld: true) == .plain)
    }
}
