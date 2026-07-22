import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("ClipStore.editText")
struct EditTextTests {

    private func makeStore() throws -> ClipStore {
        ClipStore(try AppDatabase.makeInMemory())
    }

    private func textClip(_ text: String) -> (Clip, [ClipRepresentation]) {
        let data = Data(text.utf8)
        let clip = Clip(title: Clip.makeTitle(from: text), contentHash: ContentHasher.hash(data))
        let rep = ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.plainText, data: data)
        return (clip, [rep])
    }

    @Test("editText replaces body and title")
    func editReplacesBody() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("before")
        let id = try store.insert(clip, representations: reps)

        try store.editText(clipID: id, to: "after edit")

        #expect(try store.clip(id: id)?.title == "after edit")
        let stored = try store.representations(for: id)
        #expect(stored.count == 1)
        #expect(String(data: stored[0].data, encoding: .utf8) == "after edit")
    }

    @Test("editText re-fingerprints so re-copying the new text bumps, not duplicates")
    func editRefingerprints() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("old body")
        let id = try store.insert(clip, representations: reps)

        try store.editText(clipID: id, to: "new body")

        // A fresh capture of the edited text must dedupe onto the same clip.
        let (again, areps) = textClip("new body")
        #expect(try store.insertOrBump(again, representations: areps) == .bumped(id))
    }

    @Test("editText drops rtf and html representations")
    func editDropsRich() throws {
        let store = try makeStore()
        let clip = Clip(title: "rich", contentHash: ContentHasher.hash(Data("rich".utf8)))
        let id = try store.insert(clip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.plainText, data: Data("rich".utf8)),
            ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.rtf, data: Data([0x01])),
            ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.html, data: Data("<b>rich</b>".utf8)),
        ])

        try store.editText(clipID: id, to: "plain now")

        let utis = try store.representations(for: id).map(\.utiIdentifier)
        #expect(utis == [SupportedTypes.plainText])
    }

    @Test("editText preserves a co-present image representation")
    func editKeepsImage() throws {
        let store = try makeStore()
        let clip = Clip(title: "shot+caption", contentHash: ContentHasher.hash(Data("cap".utf8)))
        let id = try store.insert(clip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.plainText, data: Data("cap".utf8)),
            ClipRepresentation(clipID: 0, utiIdentifier: "public.png", data: Data([0xAB]), thumbnail: Data([0x01])),
        ])

        try store.editText(clipID: id, to: "new caption")

        let utis = try store.representations(for: id).map(\.utiIdentifier).sorted()
        #expect(utis == ["public.png", SupportedTypes.plainText].sorted())
    }

    @Test("editText rejects empty or whitespace-only text")
    func editRejectsEmpty() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("keep me")
        let id = try store.insert(clip, representations: reps)

        #expect(throws: ClipStore.EditError.emptyText) { try store.editText(clipID: id, to: "") }
        #expect(throws: ClipStore.EditError.emptyText) { try store.editText(clipID: id, to: "   \n\t") }
        // Unchanged.
        #expect(try store.clip(id: id)?.title == "keep me")
    }
}
