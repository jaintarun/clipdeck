import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("ClipStore")
struct ClipStoreTests {

    private func makeStore() throws -> ClipStore {
        ClipStore(try AppDatabase.makeInMemory())
    }

    private func textClip(_ text: String, app: String? = nil) -> (Clip, [ClipRepresentation]) {
        let data = Data(text.utf8)
        let clip = Clip(
            title: Clip.makeTitle(from: text),
            sourceApp: app,
            contentHash: ContentHasher.hash(data)
        )
        let rep = ClipRepresentation(
            clipID: 0,
            utiIdentifier: "public.utf8-plain-text",
            data: data
        )
        return (clip, [rep])
    }

    @Test("insert returns a rowid and stores the clip")
    func insertStoresClip() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("hello world")

        let id = try store.insert(clip, representations: reps)

        #expect(id > 0)
        #expect(try store.count() == 1)
        let fetched = try #require(try store.clip(id: id))
        #expect(fetched.title == "hello world")
    }

    @Test("sourceURL round-trips through insert and fetch")
    func sourceURLRoundTrips() throws {
        let store = try makeStore()
        let (base, reps) = textClip("with url")
        var clip = base
        clip.sourceURL = "https://example.com/page"
        let id = try store.insert(clip, representations: reps)
        #expect(try store.clip(id: id)?.sourceURL == "https://example.com/page")
    }

    @Test("insert stores representations linked to the clip")
    func insertStoresRepresentations() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("payload")

        let id = try store.insert(clip, representations: reps)
        let stored = try store.representations(for: id)

        #expect(stored.count == 1)
        #expect(stored[0].utiIdentifier == "public.utf8-plain-text")
        #expect(String(data: stored[0].data, encoding: .utf8) == "payload")
        #expect(stored[0].clipID == id)
    }

    @Test("recentClips returns most-recently-used first")
    func recentClipsOrdering() throws {
        let store = try makeStore()
        for i in 1...3 {
            var (clip, reps) = textClip("clip \(i)")
            clip.createdAt = Date(timeIntervalSince1970: Double(i))
            // Set lastUsedAt explicitly: it's what ordering keys off (AMEND-1),
            // so leaving it at Date() would make this test depend on insertion
            // timing rather than on the data.
            clip.lastUsedAt = Date(timeIntervalSince1970: Double(i))
            _ = try store.insert(clip, representations: reps)
        }

        let recent = try store.recentClips()

        #expect(recent.map(\.title) == ["clip 3", "clip 2", "clip 1"])
    }

    @Test("the source app is stored")
    func storesSourceApp() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("from safari", app: "com.apple.Safari")

        let id = try store.insert(clip, representations: reps)

        #expect(try store.clip(id: id)?.sourceApp == "com.apple.Safari")
    }

    @Test("deleting a clip cascades to its representations")
    func deleteCascades() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("doomed")
        let id = try store.insert(clip, representations: reps)

        try store.delete(clipID: id)

        #expect(try store.count() == 0)
        #expect(try store.representations(for: id).isEmpty)
    }

    @Test("title is derived from the first non-empty line")
    func titleDerivation() throws {
        #expect(Clip.makeTitle(from: "\n\n  first real line\nsecond") == "first real line")
        #expect(Clip.makeTitle(from: "") == "(empty)")
        #expect(Clip.makeTitle(from: String(repeating: "x", count: 200)).hasSuffix("…"))
    }

    @Test("thumbnails(for:) batches, and returns nothing for clips without one")
    func thumbnailsBatch() throws {
        let store = try makeStore()
        // Text clip: no thumbnail.
        let (textOnly, treps) = textClip("no picture here")
        let textID = try store.insert(textOnly, representations: treps)
        // Image clip: has one.
        let imageClip = Clip(title: "shot", contentHash: ContentHasher.hash(Data([0xAB])))
        let imageID = try store.insert(imageClip, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: "public.png",
                               data: Data([0xAB]), thumbnail: Data([0x01, 0x02]))
        ])

        let thumbs = try store.thumbnails(for: [textID, imageID])

        #expect(thumbs.count == 1)
        #expect(thumbs[imageID] == Data([0x01, 0x02]))
        #expect(thumbs[textID] == nil)
    }

    @Test("thumbnails(for:) on an empty list is safe")
    func thumbnailsEmptyInput() throws {
        let store = try makeStore()
        #expect(try store.thumbnails(for: []).isEmpty)
    }

    @Test("a fresh database passes its integrity check")
    func integrityCheckPasses() throws {
        let db = try AppDatabase.makeInMemory()
        #expect(try AppDatabase.integrityCheck(db) == true)
    }

    @Test("batch delete removes clips and their representations")
    func batchDeleteRemovesClipsAndRepresentations() throws {
        let store = try makeStore()
        let (a, ra) = textClip("alpha")
        let (b, rb) = textClip("beta")
        let (c, rc) = textClip("gamma")
        let aID = try store.insert(a, representations: ra)
        let bID = try store.insert(b, representations: rb)
        let cID = try store.insert(c, representations: rc)

        try store.delete(clipIDs: [aID, bID])

        #expect(try store.count() == 1)
        #expect(try store.clip(id: aID) == nil)
        #expect(try store.representations(for: aID).isEmpty)
        #expect(try store.representations(for: bID).isEmpty)
        #expect(try store.clip(id: cID) != nil)
    }

    @Test("batch delete of an empty list is a no-op")
    func batchDeleteEmptyListIsNoOp() throws {
        let store = try makeStore()
        let (a, ra) = textClip("alpha")
        _ = try store.insert(a, representations: ra)

        try store.delete(clipIDs: [])

        #expect(try store.count() == 1)
    }

    @Test("batch delete of already-gone IDs is harmless")
    func batchDeleteMissingIDsIsHarmless() throws {
        let store = try makeStore()
        let (a, ra) = textClip("alpha")
        let aID = try store.insert(a, representations: ra)

        try store.delete(clipIDs: [aID + 100, aID + 200])

        #expect(try store.count() == 1)
    }

    // MARK: - sortKey (spec 2026-07-21)

    @Test("recentClips orders by sortKey, not lastUsedAt, when they disagree")
    func recentClipsOrdersBySortKeyNotLastUsedAt() throws {
        let queue = try AppDatabase.makeInMemory()
        let store = ClipStore(queue)
        var (older, repsOlder) = textClip("older by lastUsedAt")
        older.lastUsedAt = Date(timeIntervalSince1970: 100)
        older.sortKey = older.lastUsedAt
        let olderID = try store.insert(older, representations: repsOlder)
        var (newer, repsNewer) = textClip("newer by lastUsedAt")
        newer.lastUsedAt = Date(timeIntervalSince1970: 200)
        newer.sortKey = newer.lastUsedAt
        let newerID = try store.insert(newer, representations: repsNewer)

        // lastUsedAt says newer > older, but push older's sortKey above
        // newer's directly (as Move to Top would) — recentClips must follow
        // sortKey, not lastUsedAt.
        try queue.write { db in
            try db.execute(sql: "UPDATE clip SET sortKey = ? WHERE id = ?",
                           arguments: [Date(timeIntervalSince1970: 300), olderID])
        }

        let recent = try store.recentClips()

        #expect(recent.map(\.id) == [olderID, newerID])
    }

    @Test("insertOrBump's bump path also bumps sortKey, not just lastUsedAt")
    func bumpSetsSortKey() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("dup me")
        let id = try store.insert(clip, representations: reps)
        let later = Date(timeIntervalSince1970: 999_999)
        var rebumped = clip
        rebumped.lastUsedAt = later

        let outcome = try store.insertOrBump(rebumped, representations: reps)

        #expect(outcome == .bumped(id))
        let fetched = try #require(try store.clip(id: id))
        #expect(fetched.sortKey == later)
        #expect(fetched.lastUsedAt == later)
    }

    @Test("moveToTop sets both sortKey and lastUsedAt to now, surfacing the clip")
    func moveToTopSurfacesClip() throws {
        let store = try makeStore()
        var (older, repsOlder) = textClip("older")
        older.lastUsedAt = Date(timeIntervalSince1970: 100)
        older.sortKey = older.lastUsedAt
        let olderID = try store.insert(older, representations: repsOlder)
        var (newer, repsNewer) = textClip("newer")
        newer.lastUsedAt = Date(timeIntervalSince1970: 200)
        newer.sortKey = newer.lastUsedAt
        let newerID = try store.insert(newer, representations: repsNewer)
        let now = Date(timeIntervalSince1970: 999)

        try store.moveToTop(clipIDs: [olderID], now: now)

        let fetched = try #require(try store.clip(id: olderID))
        #expect(fetched.sortKey == now)
        #expect(fetched.lastUsedAt == now)
        #expect(try store.recentClips().map(\.id) == [olderID, newerID])
    }

    @Test("moveToTop with an empty id list is a no-op")
    func moveToTopEmptyListIsNoOp() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("alone")
        let id = try store.insert(clip, representations: reps)
        let original = try #require(try store.clip(id: id))

        try store.moveToTop(clipIDs: [])

        let after = try #require(try store.clip(id: id))
        #expect(after.sortKey == original.sortKey)
        #expect(after.lastUsedAt == original.lastUsedAt)
    }
}
