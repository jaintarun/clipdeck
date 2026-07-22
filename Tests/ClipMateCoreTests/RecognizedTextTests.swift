import Foundation
import Testing
@testable import ClipMateCore

@Suite("OCR write-back")
struct RecognizedTextTests {

    private func makeImageClip(_ store: ClipStore, title: String) throws -> Int64 {
        let clip = Clip(title: title, contentHash: ContentHasher.hash(Data([0xAB])),
                        searchText: title)
        let rep = ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.png,
                                     data: Data([0xAB]))
        return try store.insert(clip, representations: [rep])
    }

    @Test("recognized text sets title and searchText, and FTS finds it")
    func happyPath() throws {
        let store = ClipStore(try AppDatabase.makeInMemory())
        let id = try makeImageClip(store, title: "Image 7/18/26, 2:31:00 PM")

        let updated = try store.applyRecognizedText(
            clipID: id, insertedTitle: "Image 7/18/26, 2:31:00 PM",
            text: "Quarterly revenue dashboard\nQ3 2026")

        #expect(updated == true)
        #expect(try store.clip(id: id)?.title == "Quarterly revenue dashboard")
        #expect(try store.search("dashboard").map(\.id) == [id])
    }

    @Test("a user rename beats late OCR — the write is a no-op")
    func renameWins() throws {
        let store = ClipStore(try AppDatabase.makeInMemory())
        let id = try makeImageClip(store, title: "Image 7/18/26, 2:31:00 PM")
        try store.rename(clipID: id, to: "My screenshot")

        let updated = try store.applyRecognizedText(
            clipID: id, insertedTitle: "Image 7/18/26, 2:31:00 PM", text: "some text")

        #expect(updated == false)
        #expect(try store.clip(id: id)?.title == "My screenshot")
    }

    @Test("a deleted clip is a silent no-op")
    func deletedClipNoOp() throws {
        let store = ClipStore(try AppDatabase.makeInMemory())
        let id = try makeImageClip(store, title: "Image A")
        try store.delete(clipID: id)

        #expect(try store.applyRecognizedText(clipID: id, insertedTitle: "Image A",
                                              text: "ghost") == false)
    }

    @Test("empty or whitespace recognition never overwrites the generic title")
    func emptyTextNoOp() throws {
        let store = ClipStore(try AppDatabase.makeInMemory())
        let id = try makeImageClip(store, title: "Image B")

        #expect(try store.applyRecognizedText(clipID: id, insertedTitle: "Image B",
                                              text: "  \n\t ") == false)
        #expect(try store.clip(id: id)?.title == "Image B")
    }

    @Test("searchText is capped at the FTS index bound")
    func searchTextCapped() throws {
        let store = ClipStore(try AppDatabase.makeInMemory())
        let id = try makeImageClip(store, title: "Image C")
        let huge = String(repeating: "x", count: CaptureEngine.maxSearchTextChars + 500)

        _ = try store.applyRecognizedText(clipID: id, insertedTitle: "Image C", text: huge)

        #expect(try store.clip(id: id)?.searchText.count == CaptureEngine.maxSearchTextChars)
    }
}
