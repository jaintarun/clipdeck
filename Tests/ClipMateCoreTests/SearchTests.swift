import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("Search")
struct SearchTests {

    private func makeStore() throws -> ClipStore {
        ClipStore(try AppDatabase.makeInMemory())
    }

    @discardableResult
    private func add(_ store: ClipStore, _ text: String, at t: TimeInterval = 0) throws -> Int64 {
        let data = Data(text.utf8)
        let clip = Clip(
            title: Clip.makeTitle(from: text),
            createdAt: Date(timeIntervalSince1970: t),
            lastUsedAt: Date(timeIntervalSince1970: t),
            contentHash: ContentHasher.hash(data),
            searchText: text
        )
        return try store.insert(clip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: "public.utf8-plain-text", data: data)
        ])
    }

    @Test("finds a clip by a whole word")
    func findsByWord() throws {
        let store = try makeStore()
        try add(store, "Invoice 4471 for Acme Corp")
        try add(store, "unrelated text")

        let hits = try store.search("Acme")

        #expect(hits.count == 1)
        #expect(hits[0].title == "Invoice 4471 for Acme Corp")
    }

    @Test("matches on prefix — this is what type-to-filter needs")
    func findsByPrefix() throws {
        let store = try makeStore()
        try add(store, "Invoice 4471 for Acme Corp")
        try add(store, "unrelated text")

        let byInv = try store.search("inv")
        #expect(byInv.count == 1)
        #expect(byInv[0].title == "Invoice 4471 for Acme Corp")

        let byI = try store.search("i")   // no 2-char threshold
        #expect(byI.count == 1)
        #expect(byI[0].title == "Invoice 4471 for Acme Corp")
    }

    @Test("search is case-insensitive")
    func caseInsensitive() throws {
        let store = try makeStore()
        try add(store, "Invoice 4471")

        #expect(try store.search("INVOICE").count == 1)
        #expect(try store.search("invoice").count == 1)
    }

    @Test("searches body text, not just the title")
    func searchesBody() throws {
        let store = try makeStore()
        try add(store, "Line one is the title\nbut buried down here is the word platypus")

        let hits = try store.search("platypus")

        #expect(hits.count == 1)
    }

    @Test("multiple terms require all of them")
    func multipleTermsAreAnded() throws {
        let store = try makeStore()
        try add(store, "invoice acme")
        try add(store, "invoice widgets")

        #expect(try store.search("invoice acme").count == 1)
    }

    @Test("no matches returns empty, not an error")
    func noMatches() throws {
        let store = try makeStore()
        try add(store, "hello")

        #expect(try store.search("zzzz").isEmpty)
    }

    @Test("an empty or junk query returns recents rather than throwing")
    func emptyQueryIsSafe() throws {
        let store = try makeStore()
        try add(store, "hello", at: 1)
        try add(store, "world", at: 2)

        // FTS5Pattern returns nil for these; we must not crash or throw.
        #expect(try store.search("").count == 2)
        #expect(try store.search("   ").count == 2)
        #expect(try store.search("*").count == 2)
    }

    @Test("results come back newest first")
    func resultsOrderedNewestFirst() throws {
        let store = try makeStore()
        try add(store, "invoice one", at: 100)
        try add(store, "invoice two", at: 200)

        #expect(try store.search("invoice").map(\.title) == ["invoice two", "invoice one"])
    }

    @Test("deleting a clip removes it from the index")
    func deleteUpdatesIndex() throws {
        let store = try makeStore()
        let id = try add(store, "ephemeral")
        #expect(try store.search("ephemeral").count == 1)

        try store.delete(clipID: id)

        #expect(try store.search("ephemeral").isEmpty)
    }
}
