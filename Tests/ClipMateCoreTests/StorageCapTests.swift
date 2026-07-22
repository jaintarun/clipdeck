import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("Storage caps")
struct StorageCapTests {
    private func makeStores() throws -> (CollectionStore, ClipStore) {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let queue = try DatabaseQueue(configuration: config)
        try AppDatabase.migrator.migrate(queue)
        return (CollectionStore(queue), ClipStore(queue))
    }

    private func insertSized(_ clips: ClipStore, bytes: Int, at t: TimeInterval) throws -> Int64 {
        try clips.insert(
            Clip(title: "big", createdAt: Date(timeIntervalSince1970: t),
                 lastUsedAt: Date(timeIntervalSince1970: t),
                 contentHash: Data("\(t)".utf8)),
            representations: [ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.plainText,
                                                 data: Data(repeating: 0x41, count: bytes))])
    }

    @Test("bytes already in Trash don't count against the budget, so repeat passes don't cannibalise the library")
    func trashedBytesDoNotCountTowardBudget() throws {
        let (collections, clips) = try makeStores()
        // Budget fits exactly two clips.
        let caps = StorageCaps(perItemBytes: 10_000, totalBytes: 2_500)
        let old = try insertSized(clips, bytes: 1_000, at: 100)
        let mid = try insertSized(clips, bytes: 1_000, at: 200)
        let new = try insertSized(clips, bytes: 1_000, at: 300)

        // Pass 1: 3_000 bytes > 2_500, so the oldest goes to Trash. But a move
        // relocates a clipCollection row — it does NOT free the bytes, which
        // stay in clipRepresentation until an actual purge runs.
        #expect(try collections.enforceStorageCaps(caps) == 1)

        // Pass 2 is the whole point. enforceStorageCaps runs on EVERY capture.
        // If the budget counted trashed bytes, the library would still look
        // like 3_000 > 2_500 and this pass would trash `mid` too — then the
        // next would take `new`, and so on until only protected clips remain.
        // The cap would eat the library it exists to bound.
        #expect(try collections.enforceStorageCaps(caps) == 0)
        #expect(try collections.enforceStorageCaps(caps) == 0)

        let trash = try collections.collection(kind: .trash)
        #expect(try collections.clipIDs(in: trash.id!) == [old])
        #expect(try collections.collectionID(of: mid) != trash.id!)
        #expect(try collections.collectionID(of: new) != trash.id!)
        // 2_000 active bytes, under the 2_500 budget: nothing more is owed.
        #expect(try collections.activeStorageBytes() == 2_000)
    }

    @Test("over the total budget, the oldest unprotected clips are trashed until it fits")
    func totalCapTrashesOldestFirst() throws {
        let (collections, clips) = try makeStores()
        let caps = StorageCaps(perItemBytes: 10_000, totalBytes: 2_500)
        let old = try insertSized(clips, bytes: 1_000, at: 100)
        let mid = try insertSized(clips, bytes: 1_000, at: 200)
        let new = try insertSized(clips, bytes: 1_000, at: 300)

        let trashed = try collections.enforceStorageCaps(caps)

        #expect(trashed == 1)
        let trash = try collections.collection(kind: .trash)
        #expect(try collections.clipIDs(in: trash.id!) == [old])
        #expect(try collections.collectionID(of: mid) != trash.id!)
        #expect(try collections.collectionID(of: new) != trash.id!)
    }

    @Test("clips filed in Safe are exempt from the storage cap")
    func safeClipsAreExemptFromStorageCap() throws {
        let (collections, clips) = try makeStores()
        let caps = StorageCaps(perItemBytes: 10_000, totalBytes: 500)
        let pinned = try insertSized(clips, bytes: 1_000, at: 100)
        try collections.moveClips([pinned], to: collections.collection(kind: .safe).id!)

        _ = try collections.enforceStorageCaps(caps)

        let trash = try collections.collection(kind: .trash)
        #expect(try collections.clipIDs(in: trash.id!).isEmpty)
        #expect(try clips.clip(id: pinned) != nil)
    }

    @Test("when protected content alone busts the budget, we skip and warn rather than purge it")
    func protectedContentOverBudgetSkipsAndWarns() throws {
        let (collections, clips) = try makeStores()
        let caps = StorageCaps(perItemBytes: 10_000, totalBytes: 500)
        let safeID = try collections.collection(kind: .safe).id!
        let a = try insertSized(clips, bytes: 5_000, at: 100)
        let b = try insertSized(clips, bytes: 5_000, at: 200)
        try collections.moveClips([a, b], to: safeID)

        // Guide Part 4.2: skip-and-warn. Purging what the user explicitly
        // protected in order to satisfy a number they never saw is the one
        // outcome that is definitely wrong.
        let trashed = try collections.enforceStorageCaps(caps)
        #expect(trashed == 0)
        #expect(try clips.count() == 2)
    }

    @Test("protected content alone over budget: an unprotected clip is left in InBox, not trashed")
    func protectedOverBudgetLeavesUnprotectedClipUntouched() throws {
        let (collections, clips) = try makeStores()
        let caps = StorageCaps(perItemBytes: 10_000, totalBytes: 500)
        // Safe alone (1_000) already busts the 500 budget.
        let pinned = try insertSized(clips, bytes: 1_000, at: 100)
        try collections.moveClips([pinned], to: collections.collection(kind: .safe).id!)
        let unprotected = try insertSized(clips, bytes: 100, at: 200)

        let trashed = try collections.enforceStorageCaps(caps)
        #expect(trashed == 0)

        let inbox = try collections.collection(kind: .inbox)
        #expect(try collections.collectionID(of: unprotected) == inbox.id!)
        let trash = try collections.collection(kind: .trash)
        #expect(try collections.clipIDs(in: trash.id!).isEmpty)
    }

    @Test("protected content over budget with an unprotected clip present: repeated calls don't churn")
    func protectedOverBudgetRepeatedCallsDontChurn() throws {
        let (collections, clips) = try makeStores()
        let caps = StorageCaps(perItemBytes: 10_000, totalBytes: 500)
        let pinned = try insertSized(clips, bytes: 1_000, at: 100)
        try collections.moveClips([pinned], to: collections.collection(kind: .safe).id!)
        let unprotected = try insertSized(clips, bytes: 100, at: 200)

        // enforceStorageCaps runs on every capture. If it ever evicted the
        // unprotected clip once, that would already be data loss — but the
        // real danger is silent, repeated erosion. None of these three
        // simulated captures insert anything new, so all three must be 0.
        #expect(try collections.enforceStorageCaps(caps) == 0)
        #expect(try collections.enforceStorageCaps(caps) == 0)
        #expect(try collections.enforceStorageCaps(caps) == 0)

        let trash = try collections.collection(kind: .trash)
        #expect(try collections.clipIDs(in: trash.id!).isEmpty)
        let inbox = try collections.collection(kind: .inbox)
        #expect(try collections.collectionID(of: unprotected) == inbox.id!)
    }

    @Test("protected content fits under budget, unprotected clips bust it: only the oldest unprotected are trashed, and eviction stops as soon as it fits")
    func mixedProtectedFitsUnprotectedBustsBudget() throws {
        let (collections, clips) = try makeStores()
        // Budget fits the pinned clip plus one unprotected clip, but not more.
        let caps = StorageCaps(perItemBytes: 10_000, totalBytes: 2_500)
        let pinned = try insertSized(clips, bytes: 1_000, at: 50)
        try collections.moveClips([pinned], to: collections.collection(kind: .safe).id!)
        let old = try insertSized(clips, bytes: 1_000, at: 100)
        let mid = try insertSized(clips, bytes: 1_000, at: 200)
        let new = try insertSized(clips, bytes: 1_000, at: 300)

        // active = 4_000 > 2_500. Protected floor (pinned) is 1_000, which
        // fits, so this is the normal oldest-first path, not skip-and-warn.
        let trashed = try collections.enforceStorageCaps(caps)

        #expect(trashed == 2)
        let trash = try collections.collection(kind: .trash)
        // clipIDs(in:) lists newest-used first, matching every other listing.
        #expect(try collections.clipIDs(in: trash.id!) == [mid, old])
        // Stops as soon as it fits: `new` is spared, not over-evicted.
        #expect(try collections.collectionID(of: new) != trash.id!)
        #expect(try collections.collectionID(of: pinned) != trash.id!)
        #expect(try clips.clip(id: pinned) != nil)
    }

    @Test("the shipped budget is 500 MB with a 25 MB per-item cap")
    func shippedBudgetIsFiveHundredMegabytes() {
        #expect(StorageCaps.l2Default.totalBytes == 524_288_000)
        #expect(StorageCaps.l2Default.perItemBytes == 26_214_400)
    }
}
