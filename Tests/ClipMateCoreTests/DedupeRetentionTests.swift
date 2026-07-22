import Foundation
import Testing
import GRDB
@testable import ClipMateCore

@Suite("Dedupe and retention")
struct DedupeRetentionTests {

    private func makeStore() throws -> ClipStore {
        ClipStore(try AppDatabase.makeInMemory())
    }

    private func textClip(_ text: String, at t: TimeInterval = 0) -> (Clip, [ClipRepresentation]) {
        let data = Data(text.utf8)
        let clip = Clip(
            title: Clip.makeTitle(from: text),
            createdAt: Date(timeIntervalSince1970: t),
            lastUsedAt: Date(timeIntervalSince1970: t),
            contentHash: ContentHasher.hash(data)
        )
        return (clip, [ClipRepresentation(clipID: 0, utiIdentifier: "public.utf8-plain-text", data: data)])
    }

    @Test("copying something new inserts a row")
    func newContentInserts() throws {
        let store = try makeStore()
        let (clip, reps) = textClip("alpha")

        let outcome = try store.insertOrBump(clip, representations: reps)

        guard case .inserted = outcome else {
            Issue.record("expected .inserted, got \(outcome)")
            return
        }
        #expect(try store.count() == 1)
    }

    @Test("copying the same thing twice bumps instead of duplicating")
    func duplicateBumps() throws {
        let store = try makeStore()
        let (first, reps1) = textClip("same", at: 100)
        let firstID = try store.insert(first, representations: reps1)

        let (second, reps2) = textClip("same", at: 500)
        let outcome = try store.insertOrBump(second, representations: reps2)

        #expect(outcome == .bumped(firstID))
        #expect(try store.count() == 1)
        let stored = try #require(try store.clip(id: firstID))
        #expect(stored.lastUsedAt == Date(timeIntervalSince1970: 500))
        #expect(stored.createdAt == Date(timeIntervalSince1970: 100),
                "a bump must not touch createdAt — re-copy surfaces a clip, never rewrites its origin")
    }

    @Test("a bumped clip moves to the top of the list")
    func bumpedClipSurfaces() throws {
        let store = try makeStore()
        let (a, ra) = textClip("alpha", at: 100)
        let aID = try store.insert(a, representations: ra)
        let (b, rb) = textClip("beta", at: 200)
        _ = try store.insert(b, representations: rb)

        // Re-copy alpha, later than beta.
        let (a2, ra2) = textClip("alpha", at: 300)
        _ = try store.insertOrBump(a2, representations: ra2)

        let recent = try store.recentClips()
        #expect(recent.count == 2)
        #expect(recent.first?.id == aID)
        #expect(recent.first?.title == "alpha")
    }

    @Test("retention is LRU: a re-used old clip survives, an untouched newer one is evicted")
    func retentionIsLRU() throws {
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let collections = CollectionStore(writer)
        let inbox = try collections.collection(kind: .inbox)
        try collections.setRetention(.length(2), for: inbox.id!)

        let (old, ro) = textClip("old but loved", at: 100)
        let oldID = try store.insert(old, representations: ro)
        var clip2ID: Int64 = 0
        for i in 2...3 {
            let (c, r) = textClip("clip \(i)", at: TimeInterval(i * 100))
            let id = try store.insert(c, representations: r)
            if i == 2 { clip2ID = id }
        }
        // Re-use the oldest clip, making it most recently used.
        let (again, ra) = textClip("old but loved", at: 999)
        _ = try store.insertOrBump(again, representations: ra)

        _ = try collections.runRetention()

        // Recently used must survive LRU eviction — it stays in InBox, not
        // just "still exists" (the cascade never deletes on this step).
        #expect(try store.clip(id: oldID) != nil)
        #expect(try collections.collectionID(of: oldID) == inbox.id!)
        // The least-recently-used clip is the one that goes — moved to
        // Trash, not deleted; it still exists.
        let trash = try collections.collection(kind: .trash)
        #expect(try collections.collectionID(of: clip2ID) == trash.id!)
        #expect(try store.count() == 3, "nothing is destroyed by an InBox eviction")
    }

    @Test("the 1,001st clip evicts the 1st straight to Trash")
    func retentionEvictsOldest() throws {
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let collections = CollectionStore(writer)
        let inbox = try collections.collection(kind: .inbox)
        // No setRetention: this drives the SEEDED post-v6 cap (1,000) so a
        // regression in the shipped default fails a named test.

        var clip1ID: Int64 = 0
        var clip1001ID: Int64 = 0
        for i in 1...1001 {
            let (clip, reps) = textClip("clip \(i)", at: TimeInterval(i))
            let id = try store.insert(clip, representations: reps)
            if i == 1 { clip1ID = id }
            if i == 1001 { clip1001ID = id }
        }

        let outcome = try collections.runRetention()

        #expect(outcome.movedToTrash == 1)
        // The whole point of the cascade: nothing is destroyed by an InBox
        // eviction, it moves.
        #expect(try store.count() == 1001)
        let trash = try collections.collection(kind: .trash)
        #expect(try collections.collectionID(of: clip1001ID) == inbox.id!)
        #expect(try collections.collectionID(of: clip1ID) == trash.id!)
    }

    @Test("a clip purged at the end of the cascade takes its representations with it")
    func retentionCascades() throws {
        // Eviction from InBox is a MOVE — representations only actually
        // disappear once the clip is purged from Trash past its grace
        // period. This drives the doomed clip through both steps
        // (InBox -> Trash -> purge) to prove the FK cascade still deletes
        // representations at the one step that's allowed to delete.
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let collections = CollectionStore(writer)
        let inbox = try collections.collection(kind: .inbox)
        try collections.setRetention(.length(2), for: inbox.id!)

        let (doomed, dreps) = textClip("oldest", at: 1)
        let doomedID = try store.insert(doomed, representations: dreps)
        for i in 2...3 {
            let (clip, reps) = textClip("clip \(i)", at: TimeInterval(i))
            _ = try store.insert(clip, representations: reps)
        }

        _ = try collections.runRetention()   // InBox -> Trash
        let outcome = try collections.runRetention(now: Date().addingTimeInterval(8 * 86_400))   // Trash -> purge

        #expect(outcome.purged == 1)
        #expect(try store.clip(id: doomedID) == nil)
        #expect(try store.representations(for: doomedID).isEmpty)
    }

    @Test(".never retention never evicts")
    func neverKeepsEverything() throws {
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let collections = CollectionStore(writer)
        let inbox = try collections.collection(kind: .inbox)
        try collections.setRetention(.never, for: inbox.id!)

        for i in 1...50 {
            let (clip, reps) = textClip("clip \(i)", at: TimeInterval(i))
            _ = try store.insert(clip, representations: reps)
        }

        let outcome = try collections.runRetention()

        #expect(outcome == .none)
        #expect(try store.count() == 50)
        #expect(try collections.clipIDs(in: inbox.id!).count == 50)
    }

    @Test("age retention moves out only clips older than the cutoff")
    func ageRetentionCascadesOld() throws {
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let collections = CollectionStore(writer)
        let inbox = try collections.collection(kind: .inbox)
        try collections.setRetention(.age(7 * 86400), for: inbox.id!)

        let now = Date()
        var old = textClip("ancient").0
        old.createdAt = now.addingTimeInterval(-10 * 86400)
        old.lastUsedAt = old.createdAt
        let oldID = try store.insert(old, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: "public.utf8-plain-text", data: Data("ancient".utf8))
        ])
        var fresh = textClip("today").0
        fresh.createdAt = now
        fresh.lastUsedAt = now
        let freshID = try store.insert(fresh, representations: [
            ClipRepresentation(clipID: 0, utiIdentifier: "public.utf8-plain-text", data: Data("today".utf8))
        ])

        let outcome = try collections.runRetention()

        #expect(outcome.movedToTrash == 1)
        // Moved, not deleted — both clips still exist.
        #expect(try store.count() == 2)
        let trash = try collections.collection(kind: .trash)
        #expect(try collections.collectionID(of: oldID) == trash.id!)
        #expect(try collections.collectionID(of: freshID) == inbox.id!)
    }
}
