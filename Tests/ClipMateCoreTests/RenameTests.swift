import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("Rename")
struct RenameTests {

    private func makeStore() throws -> ClipStore { ClipStore(try AppDatabase.makeInMemory()) }

    private func textClip(_ text: String) -> (Clip, [ClipRepresentation]) {
        let data = Data(text.utf8)
        let clip = Clip(title: Clip.makeTitle(from: text), contentHash: ContentHasher.hash(data),
                        searchText: text)
        let rep = ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.plainText, data: data)
        return (clip, [rep])
    }

    @Test("rename updates the title and search follows the new title")
    func renameUpdatesTitleAndFTS() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("original body text")
        let id = try store.insert(clip, representations: reps)

        try store.rename(clipID: id, to: "Quarterly Report")

        #expect(try store.clip(id: id)?.title == "Quarterly Report")
        #expect(try store.search("Quarterly").contains { $0.id == id })
    }

    @Test("rename trims surrounding whitespace")
    func renameTrims() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("x")
        let id = try store.insert(clip, representations: reps)
        try store.rename(clipID: id, to: "  Padded  ")
        #expect(try store.clip(id: id)?.title == "Padded")
    }

    @Test("rename rejects a blank title and leaves the clip untouched")
    func renameRejectsBlank() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("keep me")
        let id = try store.insert(clip, representations: reps)
        #expect(throws: ClipStore.RenameError.emptyTitle) {
            try store.rename(clipID: id, to: "   ")
        }
        #expect(try store.clip(id: id)?.title == "keep me")
    }
}
