import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("Retention cascade")
struct RetentionCascadeTests {
    private func makeStores() throws -> (CollectionStore, ClipStore) {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue)
        return (CollectionStore(queue), ClipStore(queue))
    }

    private func insertClips(_ clips: ClipStore, count: Int, from: TimeInterval = 0) throws -> [Int64] {
        try (0..<count).map { i in
            let t = Date(timeIntervalSince1970: from + Double(i))
            return try clips.insert(
                Clip(title: "c\(i)", createdAt: t, lastUsedAt: t,
                     contentHash: Data("\(from)-\(i)".utf8)),
                representations: [])
        }
    }

    @Test("an over-budget InBox moves its oldest clips to Trash — it does not delete them")
    func inboxEvictsToTrash() throws {
        let (collections, clips) = try makeStores()
        let inbox = try collections.collection(kind: .inbox)
        try collections.setRetention(.length(5), for: inbox.id!)
        let ids = try insertClips(clips, count: 8)

        let outcome = try collections.runRetention()

        #expect(outcome.movedToTrash == 3)
        #expect(outcome.purged == 0)
        // The whole point: nothing was destroyed.
        #expect(try clips.count() == 8)
        let trash = try collections.collection(kind: .trash)
        #expect(try collections.clipIDs(in: trash.id!).sorted() == ids.prefix(3).sorted())
        #expect(try collections.clipIDs(in: inbox.id!).count == 5)
    }

    @Test("a never-purge collection ignores retention entirely")
    func safeNeverPurges() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        let ids = try insertClips(clips, count: 50)
        try collections.moveClips(ids, to: safe.id!)

        let outcome = try collections.runRetention()

        #expect(outcome == RetentionOutcome(movedToTrash: 0, purged: 0))
        #expect(try collections.clipIDs(in: safe.id!).count == 50)
    }

    @Test("Trash purges only after the grace period actually elapses")
    func trashPurgesAfterGrace() throws {
        let (collections, clips) = try makeStores()
        let trash = try collections.collection(kind: .trash)
        let ids = try insertClips(clips, count: 3)
        try collections.moveClips(ids, to: trash.id!)

        // Five days in: still the user's clips (grace is now 6 days).
        let fiveDays = Date().addingTimeInterval(5 * 86_400)
        #expect(try collections.runRetention(now: fiveDays).purged == 0)
        #expect(try clips.count() == 3)

        // Eight days in: gone for real.
        let eightDays = Date().addingTimeInterval(8 * 86_400)
        #expect(try collections.runRetention(now: eightDays).purged == 3)
        #expect(try clips.count() == 0)
    }

    @Test("one pass moves a clip to Trash — never straight to gone")
    func oneStepPerPass() throws {
        let (collections, clips) = try makeStores()
        let inbox = try collections.collection(kind: .inbox)
        let trash = try collections.collection(kind: .trash)
        try collections.setRetention(.length(0), for: inbox.id!)
        let ids = try insertClips(clips, count: 1)

        // If eviction and Trash's purge ran in one pass, a single copy could
        // vanish instantly and the grace period would be a lie. One pass may
        // only MOVE: the clip lands in Trash and still exists.
        let outcome = try collections.runRetention()
        #expect(outcome.movedToTrash == 1)
        #expect(outcome.purged == 0)
        #expect(try collections.collectionID(of: ids[0]) == trash.id!)
        #expect(try clips.count() == 1)
    }

    @Test("a clip filed in Safe survives retention and an over-budget purge")
    func safeClipSurvivesRetentionAndCaps() throws {
        let (collections, clips) = try makeStores()
        let safe = try collections.collection(kind: .safe)
        let ids = try insertClips(clips, count: 1)
        try collections.moveClips(ids, to: safe.id!)

        // A year from now, with a budget so small nothing unprotected could
        // survive: both destruction paths must still leave Safe alone.
        let farFuture = Date().addingTimeInterval(365 * 86_400)
        _ = try collections.runRetention(now: farFuture)
        _ = try collections.enforceStorageCaps(StorageCaps(perItemBytes: 10_000, totalBytes: 1))

        #expect(try clips.count() == 1)
        #expect(try collections.clipIDs(in: safe.id!) == ids)
    }
}
