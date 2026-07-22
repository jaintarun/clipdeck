import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("Rich capture")
struct RichCaptureTests {

    private func makeEngine(_ pb: FakePasteboard) throws -> (CaptureEngine, ClipStore) {
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let engine = CaptureEngine(
            store: store,
            pasteboard: pb,
            collections: CollectionStore(writer),
            frontmostAppProvider: { "com.apple.Safari" }
        )
        return (engine, store)
    }

    @Test("a text + RTF + HTML copy stores all three representations")
    func capturesAllRichFormats() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.changeCount += 1
        pb.types = [SupportedTypes.plainText, SupportedTypes.rtf, SupportedTypes.html]
        pb.payloads = [
            SupportedTypes.plainText: Data("hello".utf8),
            SupportedTypes.rtf: Data(#"{\rtf1\ansi hello}"#.utf8),
            SupportedTypes.html: Data("<p>hello</p>".utf8),
        ]

        guard case .captured(let id) = try engine.pollOnce() else {
            Issue.record("expected .captured"); return
        }
        let utis = Set(try store.representations(for: id).map(\.utiIdentifier))
        #expect(utis == [SupportedTypes.plainText, SupportedTypes.rtf, SupportedTypes.html])
    }

    @Test("kind of a rich web copy is HTML")
    func kindOfRichCopyIsHTML() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.changeCount += 1
        pb.types = [SupportedTypes.plainText, SupportedTypes.rtf, SupportedTypes.html]
        pb.payloads = [
            SupportedTypes.plainText: Data("hi".utf8),
            SupportedTypes.rtf: Data(#"{\rtf1 hi}"#.utf8),
            SupportedTypes.html: Data("<b>hi</b>".utf8),
        ]
        guard case .captured(let id) = try engine.pollOnce() else {
            Issue.record("expected .captured"); return
        }
        #expect(try store.kinds(for: [id])[id] == .html)
    }

    @Test("adding RTF/HTML does not change the content fingerprint")
    func richFormatsDedupeWithPlainText() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(text: "same words")
        guard case .captured = try engine.pollOnce() else { Issue.record("first capture"); return }

        pb.changeCount += 1
        pb.types = [SupportedTypes.plainText, SupportedTypes.rtf, SupportedTypes.html]
        pb.payloads = [
            SupportedTypes.plainText: Data("same words".utf8),
            SupportedTypes.rtf: Data(#"{\rtf1 same words}"#.utf8),
            SupportedTypes.html: Data("<i>same words</i>".utf8),
        ]
        guard case .bumped = try engine.pollOnce() else {
            Issue.record("expected .bumped — same primary text"); return
        }
        #expect(try store.count() == 1)
    }

    @Test("ClipKind ordering and labels")
    func clipKindOrderAndLabels() {
        #expect(ClipKind.text < ClipKind.richText)
        #expect(ClipKind.richText < ClipKind.html)
        #expect(ClipKind.html < ClipKind.image)
        #expect(ClipKind.image < ClipKind.file)
        #expect(ClipKind(uti: SupportedTypes.rtf) == .richText)
        #expect(ClipKind(uti: SupportedTypes.html) == .html)
        #expect(ClipKind(uti: SupportedTypes.plainText) == .text)
        #expect(ClipKind.richText.label == "Rich Text")
        #expect(ClipKind.html.label == "HTML")
    }

    @Test("a copy carrying public.url records an http source URL")
    func capturesSourceURL() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.changeCount += 1
        pb.types = [SupportedTypes.plainText, SupportedTypes.sourceURL]
        pb.payloads = [
            SupportedTypes.plainText: Data("Anthropic".utf8),
            SupportedTypes.sourceURL: Data("https://www.anthropic.com/news".utf8),
        ]
        guard case .captured(let id) = try engine.pollOnce() else {
            Issue.record("expected .captured"); return
        }
        #expect(try store.clip(id: id)?.sourceURL == "https://www.anthropic.com/news")
        // public.url must never become a stored representation.
        let utis = try store.representations(for: id).map(\.utiIdentifier)
        #expect(!utis.contains(SupportedTypes.sourceURL))
    }

    @Test("a non-web source URL is ignored")
    func ignoresNonWebSourceURL() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.changeCount += 1
        pb.types = [SupportedTypes.plainText, SupportedTypes.sourceURL]
        pb.payloads = [
            SupportedTypes.plainText: Data("x".utf8),
            SupportedTypes.sourceURL: Data("file:///Users/me/secret.txt".utf8),
        ]
        guard case .captured(let id) = try engine.pollOnce() else {
            Issue.record("expected .captured"); return
        }
        #expect(try store.clip(id: id)?.sourceURL == nil)
    }

    @Test("the source URL does not alter the content fingerprint")
    func sourceURLDoesNotAffectDedupe() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(text: "dedupe me")
        guard case .captured = try engine.pollOnce() else { Issue.record("first"); return }

        pb.changeCount += 1
        pb.types = [SupportedTypes.plainText, SupportedTypes.sourceURL]
        pb.payloads = [
            SupportedTypes.plainText: Data("dedupe me".utf8),
            SupportedTypes.sourceURL: Data("https://example.com".utf8),
        ]
        guard case .bumped = try engine.pollOnce() else {
            Issue.record("expected .bumped"); return
        }
        #expect(try store.count() == 1)
    }
}
