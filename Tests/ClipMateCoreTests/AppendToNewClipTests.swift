import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("ClipStore.appendToNewClip")
struct AppendToNewClipTests {

    private func makeStores() throws -> (ClipStore, CollectionStore) {
        let queue = try AppDatabase.makeInMemory()
        return (ClipStore(queue), CollectionStore(queue))
    }

    private func insertText(_ store: ClipStore, _ text: String) throws -> Int64 {
        let data = Data(text.utf8)
        let clip = Clip(title: Clip.makeTitle(from: text), contentHash: ContentHasher.hash(data))
        let rep = ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.plainText, data: data)
        return try store.insert(clip, representations: [rep])
    }

    private func body(_ store: ClipStore, _ id: Int64) throws -> String {
        let rep = try #require(try store.representations(for: id).first { $0.utiIdentifier == SupportedTypes.plainText })
        return String(data: rep.data, encoding: .utf8) ?? ""
    }

    @Test("appends text in order joined by newlines into a new clip")
    func appendsInOrder() throws {
        let (store, _) = try makeStores()
        let a = try insertText(store, "alpha")
        let b = try insertText(store, "beta")
        let c = try insertText(store, "gamma")

        let newID = try store.appendToNewClip(clipIDs: [a, b, c])

        #expect(try body(store, newID) == "alpha\nbeta\ngamma")
    }

    @Test("leaves the source clips untouched; count grows by exactly one")
    func originalsIntact() throws {
        let (store, _) = try makeStores()
        let a = try insertText(store, "one")
        let b = try insertText(store, "two")
        let before = try store.count()

        let newID = try store.appendToNewClip(clipIDs: [a, b])

        #expect(try store.count() == before + 1)
        #expect(try body(store, a) == "one")
        #expect(try body(store, b) == "two")
        #expect(newID != a && newID != b)
    }

    @Test("the new clip is filed into InBox")
    func filesIntoInbox() throws {
        let (store, collections) = try makeStores()
        let a = try insertText(store, "x")
        let b = try insertText(store, "y")

        let newID = try store.appendToNewClip(clipIDs: [a, b])

        let inbox = try collections.collection(kind: .inbox)
        #expect(try collections.clipIDs(in: inbox.id!).contains(newID))
    }

    @Test("skips image-only clips, combines the text ones")
    func skipsImages() throws {
        let (store, _) = try makeStores()
        let a = try insertText(store, "text one")
        let imgClip = Clip(title: "shot", contentHash: ContentHasher.hash(Data([0xAB])))
        let img = try store.insert(imgClip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: "public.png", data: Data([0xAB]), thumbnail: Data([0x01]))
        ])
        let b = try insertText(store, "text two")

        let newID = try store.appendToNewClip(clipIDs: [a, img, b])

        #expect(try body(store, newID) == "text one\ntext two")
    }

    @Test("throws noText when every input is image-only")
    func throwsWhenNoText() throws {
        let (store, _) = try makeStores()
        let imgClip = Clip(title: "shot", contentHash: ContentHasher.hash(Data([0xAB])))
        let img = try store.insert(imgClip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: "public.png", data: Data([0xAB]))
        ])

        #expect(throws: ClipStore.CombineError.noText) {
            try store.appendToNewClip(clipIDs: [img, img])
        }
    }

    @Test("extracts rendered text from an html-only clip")
    func extractsRenderedText() throws {
        let (store, _) = try makeStores()
        let a = try insertText(store, "plain")
        let htmlClip = Clip(title: "web", contentHash: ContentHasher.hash(Data("<p>hello</p>".utf8)))
        let html = try store.insert(htmlClip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.html, data: Data("<p>hello</p>".utf8))
        ])

        let newID = try store.appendToNewClip(clipIDs: [a, html])

        #expect(try body(store, newID) == "plain\nhello")
    }
}
