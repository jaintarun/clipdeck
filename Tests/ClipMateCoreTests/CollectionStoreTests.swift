import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("Collections schema")
struct CollectionSchemaTests {
    private func makeStore() throws -> (ClipStore, DatabaseQueue) {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue)
        return (ClipStore(queue), queue)
    }

    @Test("the three system collections are seeded exactly once")
    func systemCollectionsSeeded() throws {
        let (_, queue) = try makeStore()
        let kinds = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM collection WHERE kind IS NOT NULL ORDER BY sortKey")
        }
        #expect(kinds == ["inbox", "trash", "safe"])
    }

    @Test("Safe is seeded as never-purge, Trash as a 6-day grace, InBox at 1000")
    func systemRetentionDefaults() throws {
        let (_, queue) = try makeStore()
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, retentionType, retentionValue FROM collection WHERE kind IS NOT NULL")
        }
        let byKind = Dictionary(uniqueKeysWithValues: rows.map { ($0["kind"] as String, $0) })
        #expect(byKind["safe"]?["retentionType"] == "never")
        #expect(byKind["trash"]?["retentionType"] == "age")
        #expect(byKind["trash"]?["retentionValue"] == 518_400)
        #expect(byKind["inbox"]?["retentionType"] == "length")
        #expect(byKind["inbox"]?["retentionValue"] == 1_000)
    }

    @Test("a second collection of the same system kind is rejected")
    func systemKindIsUnique() throws {
        let (_, queue) = try makeStore()
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO collection (name, sortKey, kind, retentionType, retentionValue)
                    VALUES ('Impostor', 900, 'inbox', 'length', 5)
                    """)
            }
        }
    }

    @Test("many user collections share a NULL kind")
    func userCollectionsShareNullKind() throws {
        let (_, queue) = try makeStore()
        try queue.write { db in
            for (i, name) in ["Work", "Recipes", "Snippets"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO collection (name, sortKey, kind, retentionType, retentionValue)
                    VALUES (?, ?, NULL, 'never', 0)
                    """, arguments: [name, 500 + i * 100])
            }
        }
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection WHERE kind IS NULL")!
        }
        #expect(count == 3)
    }

    @Test("clips that predate the migration are filed into InBox, keeping their timestamps")
    func existingClipsBackfillIntoInbox() throws {
        // Migrate only through v2, insert a clip the old way, THEN run v3 —
        // this is the real upgrade path, and the only way to prove the backfill
        // works. Migrating fully first would test nothing.
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue, upTo: "v2_fts")

        let when = Date(timeIntervalSince1970: 1_000_000)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO clip (title, createdAt, lastUsedAt, contentHash, searchText)
                VALUES ('old clip', ?, ?, X'00', 'old clip')
                """, arguments: [when, when])
        }

        try AppDatabase.migrator.migrate(queue)

        let row = try queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT c.kind AS kind, cc.movedAt AS movedAt
                FROM clipCollection cc JOIN collection c ON c.id = cc.collectionID
                """)
        }
        #expect(row?["kind"] == "inbox")
        #expect(row?["movedAt"] == when)
    }

    @Test("deleting a clip cascades its membership away")
    func deletingClipCascadesMembership() throws {
        let (store, queue) = try makeStore()
        let id = try store.insert(
            Clip(title: "x", contentHash: Data([1])),
            representations: [])
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipCollection")! } == 1)
        try store.delete(clipID: id)
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipCollection")! } == 0)
    }

    @Test("the database refuses to delete a collection that still holds clips")
    func cannotDeleteNonEmptyCollection() throws {
        let (store, queue) = try makeStore()
        _ = try store.insert(Clip(title: "x", contentHash: Data([1])), representations: [])
        #expect(throws: (any Error).self) {
            try queue.write { db in try db.execute(sql: "DELETE FROM collection WHERE kind = 'inbox'") }
        }
    }
}

@Suite("CollectionStore")
struct CollectionStoreTests {
    private func makeStores() throws -> (CollectionStore, ClipStore) {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue)
        return (CollectionStore(queue), ClipStore(queue))
    }

    @Test("setting retention on a nonexistent collection throws rather than silently no-op'ing")
    func setRetentionOnMissingCollectionThrows() throws {
        let (collections, _) = try makeStores()
        #expect(throws: CollectionError.notFound) {
            try collections.setRetention(.never, for: 999)
        }
    }
}

@Suite("CollectionStore.emptyTrash")
struct EmptyTrashTests {
    private func makeStores() throws -> (CollectionStore, ClipStore) {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue)
        return (CollectionStore(queue), ClipStore(queue))
    }

    @Test("deletes every clip filed in Trash and returns the count")
    func deletesAllTrashClips() throws {
        let (collections, clips) = try makeStores()
        let trash = try collections.collection(kind: .trash)
        let ids = try (0..<3).map { i in
            try clips.insert(Clip(title: "t\(i)", contentHash: Data([UInt8(i)])), representations: [])
        }
        try collections.moveClips(ids, to: trash.id!)

        let deleted = try collections.emptyTrash()

        #expect(deleted == 3)
        for id in ids {
            #expect(try clips.clip(id: id) == nil)
        }
    }

    @Test("clips filed outside Trash are untouched")
    func leavesOtherClipsAlone() throws {
        let (collections, clips) = try makeStores()
        let trash = try collections.collection(kind: .trash)
        let safe = try collections.collection(kind: .safe)
        let trashedID = try clips.insert(Clip(title: "trashed", contentHash: Data([1])), representations: [])
        try collections.moveClips([trashedID], to: trash.id!)
        let inboxID = try clips.insert(Clip(title: "in inbox", contentHash: Data([2])), representations: [])
        let safeID = try clips.insert(Clip(title: "in safe", contentHash: Data([3])), representations: [])
        try collections.moveClips([safeID], to: safe.id!)

        let deleted = try collections.emptyTrash()

        #expect(deleted == 1)
        #expect(try clips.clip(id: trashedID) == nil)
        #expect(try clips.clip(id: inboxID) != nil)
        #expect(try clips.clip(id: safeID) != nil)
    }

    @Test("clipRepresentation rows cascade away with their clip")
    func cascadesRepresentations() throws {
        let (collections, clips) = try makeStores()
        let trash = try collections.collection(kind: .trash)
        let data = Data("hello".utf8)
        let id = try clips.insert(
            Clip(title: "hello", contentHash: Data([9])),
            representations: [ClipRepresentation(clipID: 0, utiIdentifier: "public.utf8-plain-text", data: data)])
        try collections.moveClips([id], to: trash.id!)
        #expect(try clips.representations(for: id).count == 1)

        _ = try collections.emptyTrash()

        #expect(try clips.representations(for: id).isEmpty)
    }

    @Test("emptying an already-empty Trash returns 0 and does not throw")
    func emptyTrashOnEmptyTrashIsANoOp() throws {
        let (collections, clips) = try makeStores()
        let id = try clips.insert(Clip(title: "in inbox", contentHash: Data([1])), representations: [])

        let deleted = try collections.emptyTrash()

        #expect(deleted == 0)
        #expect(try clips.clip(id: id) != nil)
    }

}

@Suite("Clip membership")
struct ClipMembershipTests {
    private func makeStores() throws -> (CollectionStore, ClipStore) {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue)
        return (CollectionStore(queue), ClipStore(queue))
    }

    @Test("a captured clip starts in InBox")
    func newClipsLandInInbox() throws {
        let (collections, clips) = try makeStores()
        let id = try clips.insert(Clip(title: "hello", contentHash: Data([1])), representations: [])
        let inbox = try collections.collection(kind: .inbox)
        #expect(try collections.collectionID(of: id) == inbox.id!)
    }

    @Test("moving a clip refiles it and resets its clock")
    func moveRefiles() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        let id = try clips.insert(Clip(title: "hello", contentHash: Data([1])), representations: [])
        try collections.moveClips([id], to: safe.id!)
        #expect(try collections.collectionID(of: id) == safe.id!)
        #expect(try collections.clipIDs(in: safe.id!) == [id])
        let inbox = try collections.collection(kind: .inbox)
        #expect(try collections.clipIDs(in: inbox.id!).isEmpty)
    }

    @Test("re-copying moved content bumps it where it lives, without dragging it back to InBox")
    func bumpDoesNotRefile() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        let clip = Clip(title: "hello", contentHash: Data([1]))
        let id = try clips.insert(clip, representations: [])
        try collections.moveClips([id], to: safe.id!)

        // The user copies the same text again. It must NOT jump back to InBox —
        // they filed it deliberately and a bump is not a re-file.
        let outcome = try clips.insertOrBump(clip, representations: [])
        #expect(outcome == .bumped(id))
        #expect(try collections.collectionID(of: id) == safe.id!)
    }

    @Test("clips(inCollection:) returns newest-first by lastUsedAt")
    func listingIsRecencyOrdered() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        let old = try clips.insert(
            Clip(title: "old", lastUsedAt: Date(timeIntervalSince1970: 100), contentHash: Data([1])),
            representations: [])
        let new = try clips.insert(
            Clip(title: "new", lastUsedAt: Date(timeIntervalSince1970: 200), contentHash: Data([2])),
            representations: [])
        try collections.moveClips([old, new], to: safe.id!)
        #expect(try clips.clips(inCollection: safe.id!).map(\.title) == ["new", "old"])
    }

    // The two tests below cover the gaps described in the Interfaces note: the
    // Task 2 versions of these methods shipped without a guard and without an
    // ORDER BY, and nothing in the suite noticed.

    @Test("clipIDs(in:) is newest-first, not whatever order SQLite feels like")
    func clipIDsAreRecencyOrdered() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        // Insert oldest-first so a missing ORDER BY plausibly returns insertion
        // order — i.e. exactly backwards — rather than accidentally passing.
        let old = try clips.insert(
            Clip(title: "old", lastUsedAt: Date(timeIntervalSince1970: 100), contentHash: Data([1])),
            representations: [])
        let mid = try clips.insert(
            Clip(title: "mid", lastUsedAt: Date(timeIntervalSince1970: 200), contentHash: Data([2])),
            representations: [])
        let new = try clips.insert(
            Clip(title: "new", lastUsedAt: Date(timeIntervalSince1970: 300), contentHash: Data([3])),
            representations: [])
        try collections.moveClips([old, mid, new], to: safe.id!)
        #expect(try collections.clipIDs(in: safe.id!) == [new, mid, old])
    }

    @Test("moving to a collection that does not exist throws a typed error")
    func moveToMissingCollectionThrows() throws {
        let (collections, clips) = try makeStores()
        let id = try clips.insert(Clip(title: "hello", contentHash: Data([1])), representations: [])
        // Not CollectionError.notFound => the guard is missing and the raw FK
        // error is leaking through instead.
        #expect(throws: CollectionError.notFound) {
            try collections.moveClips([id], to: 999_999)
        }
    }

    @Test("moving a clip whose membership row is gone throws instead of silently skipping it, rolling back the whole batch")
    func moveClipsWithDeletedMembershipThrowsAndRollsBack() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        let goodID = try clips.insert(Clip(title: "keepme", contentHash: Data([1])), representations: [])
        let deletedID = try clips.insert(Clip(title: "gone", contentHash: Data([2])), representations: [])
        // Delete cascades away the clip's clipCollection row, so by the time
        // moveClips runs, deletedID has no membership row to UPDATE — the
        // realistic version of "the clip vanished between listing and moving".
        try clips.delete(clipID: deletedID)

        #expect(throws: CollectionError.notFound) {
            try collections.moveClips([goodID, deletedID], to: safe.id!)
        }

        // The whole move must roll back: goodID stays in InBox rather than
        // ending up half-moved because deletedID failed partway through.
        let inbox = try collections.collection(kind: .inbox)
        #expect(try collections.collectionID(of: goodID) == inbox.id!)
        #expect(try collections.clipIDs(in: safe.id!).isEmpty)
    }

    // MARK: - Move-to-Safe bottom placement (spec 2026-07-21)

    @Test("moving a clip to Safe places its sortKey below Safe's previous minimum, leaving lastUsedAt untouched")
    func moveToSafePlacesAtBottom() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        let existingID = try clips.insert(
            Clip(title: "already in safe", lastUsedAt: Date(timeIntervalSince1970: 500), contentHash: Data([1])),
            representations: [])
        try collections.moveClips([existingID], to: safe.id!)
        let floor = try #require(try clips.clip(id: existingID)).sortKey

        let incomingLastUsedAt = Date(timeIntervalSince1970: 999_999)
        let incomingID = try clips.insert(
            Clip(title: "freshly filed", lastUsedAt: incomingLastUsedAt, contentHash: Data([2])),
            representations: [])

        try collections.moveClips([incomingID], to: safe.id!)

        let incoming = try #require(try clips.clip(id: incomingID))
        #expect(incoming.sortKey < floor, "the newly filed clip's sortKey must sit below Safe's previous floor")
        #expect(incoming.lastUsedAt == incomingLastUsedAt, "move-to-Safe must not touch lastUsedAt")
    }

    @Test("a 2-clip move into Safe preserves the moved clips' relative order")
    func moveMultipleToSafePreservesRelativeOrder() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        let anchorID = try clips.insert(
            Clip(title: "anchor", lastUsedAt: Date(timeIntervalSince1970: 500), contentHash: Data([1])),
            representations: [])
        try collections.moveClips([anchorID], to: safe.id!)

        let firstID = try clips.insert(
            Clip(title: "first in the moved array", lastUsedAt: Date(timeIntervalSince1970: 100), contentHash: Data([2])),
            representations: [])
        let secondID = try clips.insert(
            Clip(title: "second in the moved array", lastUsedAt: Date(timeIntervalSince1970: 200), contentHash: Data([3])),
            representations: [])

        try collections.moveClips([firstID, secondID], to: safe.id!)

        let first = try #require(try clips.clip(id: firstID))
        let second = try #require(try clips.clip(id: secondID))
        #expect(first.sortKey != second.sortKey, "the pair must not collapse to the same sortKey")
        // Deterministic full ordering: pre-existing Safe content stays on
        // top; below it, the moved pair lands in the order the placement
        // formula produces, both strictly below the prior floor.
        #expect(try collections.clipIDs(in: safe.id!) == [anchorID, firstID, secondID])
    }

    @Test("moving into an empty Safe leaves sortKey unchanged")
    func moveToEmptySafeLeavesSortKeyUnchanged() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        let id = try clips.insert(
            Clip(title: "first into safe", lastUsedAt: Date(timeIntervalSince1970: 555), contentHash: Data([1])),
            representations: [])
        let before = try #require(try clips.clip(id: id)).sortKey

        try collections.moveClips([id], to: safe.id!)

        let after = try #require(try clips.clip(id: id))
        #expect(after.sortKey == before)
    }

    @Test("moving to a non-Safe collection (Trash) leaves sortKey unchanged")
    func moveToTrashLeavesSortKeyUnchanged() throws {
        let (collections, clips) = try makeStores()
        let trash = try collections.collection(kind: .trash)
        let id = try clips.insert(
            Clip(title: "doomed", lastUsedAt: Date(timeIntervalSince1970: 555), contentHash: Data([1])),
            representations: [])
        let before = try #require(try clips.clip(id: id)).sortKey

        try collections.moveClips([id], to: trash.id!)

        let after = try #require(try clips.clip(id: id))
        #expect(after.sortKey == before)
    }
}
