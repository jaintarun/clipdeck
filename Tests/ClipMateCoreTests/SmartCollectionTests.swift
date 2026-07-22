import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("Smart collections")
struct SmartCollectionTests {

    private func makeStore() throws -> ClipStore {
        ClipStore(try AppDatabase.makeInMemory())
    }

    @discardableResult
    private func addText(_ store: ClipStore, _ text: String, at date: Date) throws -> Int64 {
        let data = Data(text.utf8)
        let clip = Clip(
            title: Clip.makeTitle(from: text),
            createdAt: date,
            lastUsedAt: date,
            contentHash: ContentHasher.hash(data),
            searchText: text
        )
        return try store.insert(clip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: "public.utf8-plain-text", data: data)
        ])
    }

    @discardableResult
    private func addImage(_ store: ClipStore, _ name: String, at date: Date) throws -> Int64 {
        let data = Data(repeating: 0xAB, count: 32)
        let clip = Clip(
            title: name,
            createdAt: date,
            lastUsedAt: date,
            contentHash: ContentHasher.hash(data + Data(name.utf8)),
            searchText: name
        )
        return try store.insert(clip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: "public.png", data: data, thumbnail: Data([0x01]))
        ])
    }

    @Test("inbox returns everything, newest first")
    func inboxReturnsAll() throws {
        let store = try makeStore()
        try addText(store, "old", at: Date(timeIntervalSince1970: 100))
        try addText(store, "new", at: Date(timeIntervalSince1970: 200))

        #expect(try store.clips(in: .inbox).map(\.title) == ["new", "old"])
    }

    @Test("today excludes yesterday")
    func todayFiltersByDay() throws {
        let store = try makeStore()
        try addText(store, "right now", at: Date())
        try addText(store, "yesterday", at: Date().addingTimeInterval(-26 * 3600))

        #expect(try store.clips(in: .today).map(\.title) == ["right now"])
    }

    @Test("this week excludes a month ago")
    func thisWeekFilters() throws {
        let store = try makeStore()
        try addText(store, "recent", at: Date().addingTimeInterval(-2 * 86400))
        try addText(store, "ancient", at: Date().addingTimeInterval(-30 * 86400))

        #expect(try store.clips(in: .thisWeek).map(\.title) == ["recent"])
    }

    @Test("images returns only clips carrying an image representation")
    func imagesFiltersByType() throws {
        let store = try makeStore()
        try addText(store, "just text", at: Date())
        try addImage(store, "Screenshot 1", at: Date())

        let hits = try store.clips(in: .images)

        #expect(hits.count == 1)
        #expect(hits[0].title == "Screenshot 1")
    }

    @Test("a clip with both text and image counts as an image, listed once")
    func mixedClipCountsOnceAsImage() throws {
        let store = try makeStore()
        let data = Data(repeating: 0x01, count: 8)
        let clip = Clip(
            title: "mixed",
            contentHash: ContentHasher.hash(data),
            searchText: "mixed"
        )
        // Two representations satisfy the image-UTI WHERE clause (png and
        // tiff — apps commonly offer a copied image under both), plus a
        // text representation that doesn't. That's 2 joined rows for 1
        // clip, so DISTINCT is what collapses them to a single hit.
        let id = try store.insert(clip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: "public.utf8-plain-text", data: Data("mixed".utf8)),
            ClipRepresentation(clipID: 0, utiIdentifier: "public.png", data: data, thumbnail: Data([0x02])),
            ClipRepresentation(clipID: 0, utiIdentifier: "public.tiff", data: data, thumbnail: Data([0x03])),
        ])

        let hits = try store.clips(in: .images)

        #expect(hits.count == 1, "a clip with 2 image representations must not appear twice")
        #expect(hits.first?.id == id)
    }

    @Test("everything matches inbox in L1")
    func everythingMatchesInbox() throws {
        let store = try makeStore()
        try addText(store, "a", at: Date(timeIntervalSince1970: 1))
        try addText(store, "b", at: Date(timeIntervalSince1970: 2))

        #expect(try store.clips(in: .everything).count == store.clips(in: .inbox).count)
    }

    @Test("empty collections return empty, not an error")
    func emptyIsFine() throws {
        let store = try makeStore()
        #expect(try store.clips(in: .images).isEmpty)
        #expect(try store.clips(in: .today).isEmpty)
    }

    @Test("every case has a title and an icon")
    func allCasesPresentable() {
        for c in SmartCollection.allCases {
            #expect(!c.title.isEmpty)
            #expect(!c.systemImageName.isEmpty)
        }
    }
}
