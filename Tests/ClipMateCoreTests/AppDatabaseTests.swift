import Foundation
import Testing
import GRDB
@testable import ClipMateCore

/// The production path, exercised for the first time.
///
/// Every other test in this package builds its store via
/// `AppDatabase.makeInMemory()` — a `DatabaseQueue` with one read-write
/// connection. Production calls `AppDatabase.makePool(at:)` — a
/// `DatabasePool` whose reader connections are opened READ-ONLY. Nothing
/// here mocks that away: each test opens a real on-disk `DatabasePool` in a
/// unique temp directory so a regression in `makeConfiguration()` (like a
/// pragma that writes the file header) shows up the same way it did in
/// production, and never touches the user's real database.
@Suite("AppDatabase")
struct AppDatabaseTests {

    /// A fresh temp directory per test, so parallel tests and reruns never
    /// collide, and the user's `~/Library/Application Support/ClipMateMac/`
    /// is never touched.
    private func makeTempDatabaseURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clips.sqlite")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("makePool produces a pool that can actually be read from")
    func makePoolCanBeRead() throws {
        let url = try makeTempDatabaseURL()
        defer { cleanup(url) }

        let pool = try AppDatabase.makePool(at: url)

        // The regression test: before Fix 1, prepareDatabase runs
        // `PRAGMA auto_vacuum = INCREMENTAL` on every connection, including
        // the pool's read-only reader connections, and every read throws
        // "SQLite error 8: attempt to write a readonly database".
        let count = try pool.read { db in try Clip.fetchCount(db) }

        #expect(count == 0)
    }

    @Test("auto_vacuum is still applied (INCREMENTAL), not silently dropped")
    func autoVacuumStillApplied() throws {
        let url = try makeTempDatabaseURL()
        defer { cleanup(url) }

        let pool = try AppDatabase.makePool(at: url)

        // 2 == INCREMENTAL. This is the control: it stops someone "fixing"
        // the readonly error by just deleting the pragma outright.
        let mode = try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") }

        #expect(mode == 2)
    }

    @Test("foreign_keys is ON for both the writer and reader connections")
    func foreignKeysOnBothConnections() throws {
        let url = try makeTempDatabaseURL()
        defer { cleanup(url) }

        let pool = try AppDatabase.makePool(at: url)

        let writerValue = try pool.write { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
        let readerValue = try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }

        #expect(writerValue == 1)
        #expect(readerValue == 1)
    }

    @Test("a real insert and read round-trips through the on-disk pool")
    func insertAndReadRoundTripsThroughPool() throws {
        let url = try makeTempDatabaseURL()
        defer { cleanup(url) }

        let pool = try AppDatabase.makePool(at: url)
        let store = ClipStore(pool)
        let data = Data("hello disk".utf8)
        let clip = Clip(title: "hello disk", contentHash: ContentHasher.hash(data))
        let rep = ClipRepresentation(clipID: 0, utiIdentifier: "public.utf8-plain-text", data: data)

        let id = try store.insert(clip, representations: [rep])
        let fetched = try store.recentClips()

        #expect(fetched.count == 1)
        #expect(fetched.first?.id == id)
        #expect(fetched.first?.title == "hello disk")
    }

    // MARK: - isCorruption

    @Test("a readonly error is not classified as corruption")
    func readonlyErrorIsNotCorruption() throws {
        let error = DatabaseError(resultCode: .SQLITE_READONLY)
        #expect(AppDatabase.isCorruption(error) == false)
    }

    @Test("a non-DatabaseError is not classified as corruption")
    func nonDatabaseErrorIsNotCorruption() throws {
        struct SomeOtherError: Error {}
        #expect(AppDatabase.isCorruption(SomeOtherError()) == false)
    }

    @Test("SQLITE_CORRUPT is classified as corruption")
    func sqliteCorruptIsCorruption() throws {
        let error = DatabaseError(resultCode: .SQLITE_CORRUPT)
        #expect(AppDatabase.isCorruption(error) == true)
    }

    @Test("SQLITE_NOTADB is classified as corruption")
    func sqliteNotADBIsCorruption() throws {
        let error = DatabaseError(resultCode: .SQLITE_NOTADB)
        #expect(AppDatabase.isCorruption(error) == true)
    }

    // MARK: - Fix 3: incremental_vacuum actually reclaims space

    private func fileSize(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return attrs[.size] as? Int ?? -1
    }

    /// auto_vacuum = INCREMENTAL only marks freed pages reusable; the file
    /// never shrinks unless something runs `PRAGMA incremental_vacuum`, and in
    /// WAL mode that shrink only reaches the on-disk file at a checkpoint.
    /// Under the cascade, nothing is actually destroyed until Trash purges
    /// past its grace period — that is the one moment pages are freed, so
    /// `runRetention` must run both then — otherwise the file is a permanent
    /// high-water mark after a burst of big screenshots is purged, even
    /// though the rows are long gone.
    @Test("purging a large blob from Trash actually shrinks the file on disk")
    func retentionEvictionShrinksFileOnDisk() throws {
        let url = try makeTempDatabaseURL()
        defer { cleanup(url) }

        let pool = try AppDatabase.makePool(at: url)
        let store = ClipStore(pool)
        let collections = CollectionStore(pool)
        let trash = try collections.collection(kind: .trash)

        let bigData = Data(repeating: 0xAB, count: 20 * 1024 * 1024)
        let clip = Clip(title: "big screenshot", contentHash: ContentHasher.hash(bigData))
        let rep = ClipRepresentation(clipID: 0, utiIdentifier: "public.png", data: bigData)
        let id = try store.insert(clip, representations: [rep])
        try collections.moveClips([id], to: trash.id!)

        let sizeBeforeEviction = try fileSize(url)
        #expect(sizeBeforeEviction > 15 * 1024 * 1024, "the 20MB blob must actually be on disk before eviction")

        // Trash's grace period is 6 days; 8 days in, the clip is purged for
        // real — the same retention path CaptureEngine.process() runs after
        // every capture (spec §6).
        let outcome = try collections.runRetention(now: Date().addingTimeInterval(8 * 86_400))
        #expect(outcome.purged == 1)

        let sizeAfterEviction = try fileSize(url)
        #expect(
            sizeAfterEviction < sizeBeforeEviction / 2,
            "purging a large blob must shrink the file, not just free internal pages — was \(sizeBeforeEviction) bytes, still \(sizeAfterEviction) bytes after eviction"
        )
    }

    /// Same reasoning as `retentionEvictionShrinksFileOnDisk` above, but for
    /// `emptyTrash` — the brief requires it to mirror `runRetention`'s
    /// checkpoint exactly, and a mirrored comment is not proof it actually
    /// runs against the real on-disk WAL pool.
    @Test("emptyTrash shrinks the file on disk, the same way runRetention's purge does")
    func emptyTrashShrinksFileOnDisk() throws {
        let url = try makeTempDatabaseURL()
        defer { cleanup(url) }

        let pool = try AppDatabase.makePool(at: url)
        let store = ClipStore(pool)
        let collections = CollectionStore(pool)
        let trash = try collections.collection(kind: .trash)

        let bigData = Data(repeating: 0xCD, count: 20 * 1024 * 1024)
        let clip = Clip(title: "big screenshot", contentHash: ContentHasher.hash(bigData))
        let rep = ClipRepresentation(clipID: 0, utiIdentifier: "public.png", data: bigData)
        let id = try store.insert(clip, representations: [rep])
        try collections.moveClips([id], to: trash.id!)

        let sizeBeforeEmpty = try fileSize(url)
        #expect(sizeBeforeEmpty > 15 * 1024 * 1024, "the 20MB blob must actually be on disk before Empty Trash")

        let deleted = try collections.emptyTrash()
        #expect(deleted == 1)

        let sizeAfterEmpty = try fileSize(url)
        #expect(
            sizeAfterEmpty < sizeBeforeEmpty / 2,
            "emptyTrash must shrink the file, not just free internal pages — was \(sizeBeforeEmpty) bytes, still \(sizeAfterEmpty) bytes after"
        )
    }

    // MARK: - Fix 5: the full store surface against the real production writer

    /// The two worst bugs on this branch both came from a test double
    /// diverging from shipping code. Every other suite in this package
    /// builds its store via `AppDatabase.makeInMemory()` (`DatabaseQueue`);
    /// only this file touches the real `makePool()` (`DatabasePool`), and
    /// only for narrow, single-purpose checks. This test drives the rest of
    /// `ClipStore`'s surface — insertOrBump, the retention cascade, search,
    /// clips(in:), thumbnails(for:) — against a real on-disk `DatabasePool`,
    /// in the same insertOrBump → runRetention sequence `CaptureEngine.process()`
    /// runs on every capture, so a regression that only shows up against
    /// read-only reader connections has somewhere to surface.
    @Test("insertOrBump, the retention cascade, search, clips(in:), and thumbnails all behave correctly against a real on-disk pool")
    func fullStoreSurfaceAgainstRealPool() throws {
        let url = try makeTempDatabaseURL()
        defer { cleanup(url) }

        let pool = try AppDatabase.makePool(at: url)
        let store = ClipStore(pool)
        let collections = CollectionStore(pool)
        let systemInbox = try collections.collection(kind: .inbox)

        // Mirrors CaptureEngine.process(): insertOrBump() then runRetention()
        // on every capture (spec §6).
        func capture(_ text: String, at t: TimeInterval, image: Data? = nil) throws -> Int64 {
            let data = Data(text.utf8)
            let clip = Clip(
                title: Clip.makeTitle(from: text),
                createdAt: Date(timeIntervalSince1970: t),
                lastUsedAt: Date(timeIntervalSince1970: t),
                contentHash: ContentHasher.hash(data),
                searchText: text
            )
            var reps = [ClipRepresentation(clipID: 0, utiIdentifier: "public.utf8-plain-text", data: data)]
            if let image {
                reps.append(ClipRepresentation(
                    clipID: 0, utiIdentifier: "public.png", data: image, thumbnail: Data([0x01, 0x02])))
            }
            let outcome = try store.insertOrBump(clip, representations: reps)
            try collections.runRetention()
            switch outcome {
            case .inserted(let id), .bumped(let id):
                return id
            }
        }

        let alphaID = try capture("alpha rocket launch", at: 100)
        let betaID = try capture("beta report", at: 200, image: Data([0xAB, 0xCD]))
        let gammaID = try capture("gamma notes", at: 300)

        // insertOrBump: re-capturing identical content bumps the SAME row
        // (identity), not a twin (spec §6).
        let alphaAgainID = try capture("alpha rocket launch", at: 400)
        #expect(alphaAgainID == alphaID, "re-capturing identical content must bump, not duplicate")
        #expect(try store.count() == 3, "the dedupe bump must not have added a 4th row")

        // clips(in:): ordering follows lastUsedAt (AMEND-1) — alpha was just
        // re-captured, so it leads despite being captured first. (This is the
        // SmartCollection.inbox query — all clips, unfiltered — distinct from
        // CollectionStore's InBox membership checked below.)
        let inbox = try store.clips(in: .inbox)
        #expect(inbox.map(\.id) == [alphaID, gammaID, betaID])
        #expect(inbox.map(\.title) == ["alpha rocket launch", "gamma notes", "beta report"])

        // search(): FTS5 over the real on-disk index.
        let searchResults = try store.search("rocket")
        #expect(searchResults.map(\.id) == [alphaID], "FTS5 must find the term in searchText on the real pool")

        // thumbnails(for:): batched, image-only.
        let thumbs = try store.thumbnails(for: [alphaID, betaID])
        #expect(thumbs[betaID] == Data([0x01, 0x02]))
        #expect(thumbs[alphaID] == nil)

        // The cascade: filing beta into Safe exempts it from InBox's budget
        // (D1 — Safe membership is the only protection mechanism). A
        // length(1) InBox budget then moves out the least-recently-used clip
        // still filed there (gamma). It MOVES rather than deletes — gamma
        // still exists, just no longer filed in InBox.
        let safe = try collections.collection(kind: .safe)
        try collections.moveClips([betaID], to: safe.id!)
        try collections.setRetention(.length(1), for: systemInbox.id!)
        let outcome = try collections.runRetention()
        #expect(outcome.movedToTrash == 1)
        #expect(try store.count() == 3, "the cascade moves clips out of InBox, it does not delete them")
        let remainingInInbox = try collections.clipIDs(in: systemInbox.id!)
        #expect(remainingInInbox == [alphaID])
        let trash = try collections.collection(kind: .trash)
        #expect(try collections.collectionID(of: gammaID) == trash.id!)
        #expect(try collections.collectionID(of: betaID) == safe.id!)
    }
}

@Suite("Trash grace migration (v5)")
struct TrashGraceMigrationTests {
    /// A bare queue with ClipMate's connection config but NO migrations run,
    /// so a test can stop the migrator mid-history and edit rows in between.
    private func makeUnmigratedQueue() throws -> DatabaseQueue {
        try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    }

    private func trashRetentionValue(_ queue: DatabaseQueue) throws -> Int? {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT retentionValue FROM collection WHERE kind = 'trash'")
        }
    }

    @Test("an existing 7-day Trash row migrates to 6 days")
    func defaultTrashRowConverts() throws {
        let queue = try makeUnmigratedQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4_sourceURL")
        // v3's seed wrote the old 7-day default; prove that's the input state.
        #expect(try trashRetentionValue(queue) == 604_800)

        try AppDatabase.migrator.migrate(queue)

        #expect(try trashRetentionValue(queue) == 518_400)
    }

    @Test("a user-customized Trash retention is not clobbered")
    func customizedTrashRowUntouched() throws {
        let queue = try makeUnmigratedQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4_sourceURL")
        // The user dialed Trash down to 3 days before upgrading.
        try queue.write { db in
            try db.execute(sql: "UPDATE collection SET retentionValue = 259200 WHERE kind = 'trash'")
        }

        try AppDatabase.migrator.migrate(queue)

        #expect(try trashRetentionValue(queue) == 259_200)
    }

    @Test("a fresh database ends at the 6-day grace")
    func freshDatabaseEndsAtSixDays() throws {
        let queue = try AppDatabase.makeInMemory()
        #expect(try trashRetentionValue(queue) == 518_400)
    }
}

@Suite("Overflow removal migration (v6)")
struct OverflowRemovalMigrationTests {
    /// Stops the migrator at v5 — the last version where the Overflow row
    /// exists — so tests can stage pre-v6 data with plain SQL (never the
    /// enum, which no longer has an overflow case).
    private func makeQueueAtV5() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
        try AppDatabase.migrator.migrate(queue, upTo: "v5_trash_six_days")
        return queue
    }

    private func inboxCap(_ queue: DatabaseQueue) throws -> Int? {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT retentionValue FROM collection WHERE kind = 'inbox'")
        }
    }

    @Test("Overflow members merge into InBox with movedAt preserved")
    func membersMergeIntoInbox() throws {
        let queue = try makeQueueAtV5()
        // Raw SQL, not ClipStore.insert: at v5 the clip table has no sortKey
        // column yet (that's v8), and ClipStore.insert now writes one.
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let id = try queue.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO clip (title, createdAt, lastUsedAt, contentHash, searchText)
                VALUES ('stranded', ?, ?, ?, 'stranded')
                """, arguments: [anchor, anchor, Data("stranded".utf8)])
            let id = db.lastInsertedRowID
            // File it in Overflow at a fixed timestamp — v6 must keep this
            // exact movedAt (a bucket merge is not a user action; age is
            // preserved).
            try db.execute(sql: """
                INSERT INTO clipCollection (clipID, collectionID, movedAt)
                VALUES (?, (SELECT id FROM collection WHERE kind = 'overflow'), ?)
                """, arguments: [id, anchor])
            return id
        }

        try AppDatabase.migrator.migrate(queue)

        let kind = try queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT c.kind FROM clipCollection cc
                JOIN collection c ON c.id = cc.collectionID
                WHERE cc.clipID = ?
                """, arguments: [id])
        }
        let movedAt = try queue.read { db in
            try Date.fetchOne(db, sql: "SELECT movedAt FROM clipCollection WHERE clipID = ?",
                              arguments: [id])
        }
        #expect(kind == "inbox")
        #expect(movedAt == anchor)
    }

    @Test("the InBox cap rises from 200 to 1000")
    func inboxCapRaised() throws {
        let queue = try makeQueueAtV5()
        #expect(try inboxCap(queue) == 200)

        try AppDatabase.migrator.migrate(queue)

        #expect(try inboxCap(queue) == 1_000)
    }

    @Test("a user-customized InBox cap is not clobbered")
    func customizedInboxCapUntouched() throws {
        let queue = try makeQueueAtV5()
        try queue.write { db in
            try db.execute(sql: "UPDATE collection SET retentionValue = 500 WHERE kind = 'inbox'")
        }

        try AppDatabase.migrator.migrate(queue)

        #expect(try inboxCap(queue) == 500)
    }

    @Test("a fresh database ends with three system collections and no Overflow row")
    func freshDatabaseHasThreeSystemCollections() throws {
        let queue = try AppDatabase.makeInMemory()
        let kinds = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM collection WHERE kind IS NOT NULL ORDER BY sortKey")
        }
        #expect(kinds == ["inbox", "trash", "safe"])
        #expect(try inboxCap(queue) == 1_000)
    }
}

@Suite("User collection removal migration (v7)")
struct UserCollectionRemovalMigrationTests {
    /// Stops the migrator at v6 — the last version where user collections
    /// still exist — so tests can stage one with plain SQL.
    private func makeQueueAtV6() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
        try AppDatabase.migrator.migrate(queue, upTo: "v6_remove_overflow")
        return queue
    }

    private func insertUserCollection(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO collection (name, sortKey, retentionType, retentionValue)
                VALUES ('Projects', 900, 'never', 0)
                """)
        }
    }

    @Test("a user collection's members merge into InBox with movedAt preserved")
    func membersMergeIntoInbox() throws {
        let queue = try makeQueueAtV6()
        try insertUserCollection(queue)
        // Raw SQL, not ClipStore.insert: at v6 the clip table has no sortKey
        // column yet (that's v8), and ClipStore.insert now writes one.
        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let id = try queue.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO clip (title, createdAt, lastUsedAt, contentHash, searchText)
                VALUES ('filed', ?, ?, ?, 'filed')
                """, arguments: [anchor, anchor, Data("filed".utf8)])
            let id = db.lastInsertedRowID
            // File it in the user collection at a fixed timestamp — v7 must
            // keep this exact movedAt (a bucket merge is not a user action;
            // age is preserved).
            try db.execute(sql: """
                INSERT INTO clipCollection (clipID, collectionID, movedAt)
                VALUES (?, (SELECT id FROM collection WHERE name = 'Projects'), ?)
                """, arguments: [id, anchor])
            return id
        }

        try AppDatabase.migrator.migrate(queue)

        let kind = try queue.read { db in
            try String.fetchOne(db, sql: """
                SELECT c.kind FROM clipCollection cc
                JOIN collection c ON c.id = cc.collectionID
                WHERE cc.clipID = ?
                """, arguments: [id])
        }
        let movedAt = try queue.read { db in
            try Date.fetchOne(db, sql: "SELECT movedAt FROM clipCollection WHERE clipID = ?",
                              arguments: [id])
        }
        #expect(kind == "inbox")
        #expect(movedAt == anchor)
    }

    @Test("no kind IS NULL rows remain after migration, and the three system rows are untouched")
    func noUserCollectionsRemainSystemRowsUntouched() throws {
        let queue = try makeQueueAtV6()
        try insertUserCollection(queue)
        let before = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT kind, retentionType, retentionValue FROM collection
                WHERE kind IS NOT NULL ORDER BY sortKey
                """)
        }

        try AppDatabase.migrator.migrate(queue)

        let nullCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection WHERE kind IS NULL")!
        }
        #expect(nullCount == 0)

        let after = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT kind, retentionType, retentionValue FROM collection
                WHERE kind IS NOT NULL ORDER BY sortKey
                """)
        }
        #expect(after == before)
    }

    @Test("a fresh database ends up with exactly three collections")
    func freshDatabaseHasExactlyThreeCollections() throws {
        let queue = try AppDatabase.makeInMemory()
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection")!
        }
        #expect(count == 3)
    }
}

@Suite("Sort key migration (v8)")
struct SortKeyMigrationTests {
    /// Stops the migrator at v7 — the last version before sortKey exists —
    /// so a test can stage a pre-existing row with plain SQL.
    private func makeQueueAtV7() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
        try AppDatabase.migrator.migrate(queue, upTo: "v7_remove_user_collections")
        return queue
    }

    @Test("an existing row backfills sortKey from its lastUsedAt")
    func backfillsFromLastUsedAt() throws {
        let queue = try makeQueueAtV7()
        let when = Date(timeIntervalSince1970: 1_000_000)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO clip (title, createdAt, lastUsedAt, contentHash, searchText)
                VALUES ('old clip', ?, ?, X'00', 'old clip')
                """, arguments: [when, when])
        }

        try AppDatabase.migrator.migrate(queue)

        let sortKey = try queue.read { db in try Date.fetchOne(db, sql: "SELECT sortKey FROM clip") }
        #expect(sortKey == when)
    }

    @Test("the sortKey index exists after migration")
    func sortKeyIndexExists() throws {
        let queue = try AppDatabase.makeInMemory()
        let indexNames = try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'clip'
                """)
        }
        #expect(indexNames.contains("clip_on_sortKey"))
    }
}
