import Foundation
import GRDB

public enum CollectionError: Error, Equatable {
    case systemCollectionImmutable
    case notFound
}

/// Collections and membership. Separate from ClipStore, which is already large
/// and is about clips rather than about the tree they live in.
///
/// Not an actor, for the same reason ClipStore isn't: GRDB's DatabaseWriter is
/// already Sendable and serializes its own writes.
public final class CollectionStore: Sendable {
    private let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) { self.writer = writer }

    public func all() throws -> [Collection] {
        try writer.read { db in
            try Collection.order(Collection.Columns.sortKey).fetchAll(db)
        }
    }

    /// System collections are seeded by the migration, so absence is corruption
    /// rather than a normal miss — hence throwing instead of returning nil.
    public func collection(kind: CollectionKind) throws -> Collection {
        try writer.read { db in
            guard let c = try Collection
                .filter(Collection.Columns.kind == kind.rawValue)
                .fetchOne(db)
            else { throw CollectionError.notFound }
            return c
        }
    }

    public func setRetention(_ retention: Retention, for collectionID: Int64) throws {
        try writer.write { db in
            guard try Collection.fetchOne(db, key: collectionID) != nil else {
                throw CollectionError.notFound
            }
            try db.execute(sql: "UPDATE collection SET retentionType = ?, retentionValue = ? WHERE id = ?",
                           arguments: [retention.storedType, retention.storedValue, collectionID])
        }
    }

    /// Moves clips into a collection, e.g. filing an InBox item into Safe.
    /// Resets `movedAt` (see ClipCollection's doc comment): the cascade's
    /// grace periods measure time-in-collection, not age-of-clip.
    public func moveClips(_ clipIDs: [Int64], to collectionID: Int64) throws {
        guard !clipIDs.isEmpty else { return }
        try writer.write { db in
            // Without this, a bad destination surfaces as a raw SQLite FK error
            // rather than something a caller can catch and explain.
            guard try Collection.fetchOne(db, key: collectionID) != nil else {
                throw CollectionError.notFound
            }
            let now = Date()
            for clipID in clipIDs {
                try db.execute(sql: """
                    UPDATE clipCollection SET collectionID = ?, movedAt = ? WHERE clipID = ?
                    """, arguments: [collectionID, now, clipID])
                // A clipID with no membership row (deleted/purged between the
                // caller listing it and this move) matches zero rows above and
                // would otherwise pass as success while silently not moving.
                guard db.changesCount == 1 else { throw CollectionError.notFound }
            }

            // Spec 2026-07-21: filing into Safe appends at its BOTTOM — Safe
            // reads top-down like a notebook. Relative order of a multi-clip
            // move is preserved below the current floor. lastUsedAt untouched
            // (Safe is .never — eviction order can't diverge from display
            // where eviction is impossible). No other members: leave sortKey.
            if let dest = try Collection.fetchOne(db, key: collectionID), dest.kind == .safe {
                let movedList = clipIDs.map(\.description).joined(separator: ",")
                if let floor = try Date.fetchOne(db, sql: """
                    SELECT MIN(clip.sortKey) FROM clip
                    JOIN clipCollection cc ON cc.clipID = clip.id
                    WHERE cc.collectionID = ? AND clip.id NOT IN (\(movedList))
                    """, arguments: [collectionID]) {
                    for (offset, clipID) in clipIDs.enumerated() {
                        let key = floor.addingTimeInterval(-Double(offset + 1))
                        try db.execute(sql: "UPDATE clip SET sortKey = ? WHERE id = ?",
                                       arguments: [key, clipID])
                    }
                }
            }
        }
    }

    /// The clip ids currently filed in a collection. Newest-first, matching
    /// every other listing in the app.
    public func clipIDs(in collectionID: Int64) throws -> [Int64] {
        try writer.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT cc.clipID FROM clipCollection cc
                JOIN clip ON clip.id = cc.clipID
                WHERE cc.collectionID = ?
                ORDER BY clip.sortKey DESC
                """, arguments: [collectionID])
        }
    }

    /// The collection a clip currently lives in.
    public func collectionID(of clipID: Int64) throws -> Int64? {
        try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT collectionID FROM clipCollection WHERE clipID = ?",
                               arguments: [clipID])
        }
    }

    // MARK: - Retention cascade

    /// The cascade: InBox -> Trash -> gone.
    ///
    /// Every step but the last is a MOVE. L1's enforce() deleted; this does not.
    /// A clip only ceases to exist after it has sat in Trash past its grace period,
    /// which gives the user days to notice a mistake.
    ///
    /// Runs one step per pass by design (see `oneStepPerPass`): clips evicted from
    /// InBox land in Trash and are only PURGED by a later pass once they age out,
    /// so a tight budget can never launder a fresh clip straight out of existence.
    ///
    /// `now` is injectable so the age tests are deterministic instead of sleeping.
    @discardableResult
    public func runRetention(now: Date = Date()) throws -> RetentionOutcome {
        let outcome = try writer.write { db -> RetentionOutcome in
            let all = try Collection.fetchAll(db)
            guard let trashID = all.first(where: { $0.kind == .trash })?.id else {
                throw CollectionError.notFound
            }

            // Evaluation order matters: any collection can feed newly-evicted
            // clips into Trash, and writes inside this transaction are visible
            // to later reads in the same transaction. Evaluating Trash FIRST
            // guarantees a clip moved into Trash by a feeder's step is never
            // re-queried and purged in the same pass — which is exactly what
            // `oneStepPerPass` forbids.
            let ordered =
                all.filter { $0.kind == .trash }
                + all.filter { $0.kind != .trash }

            var movedToTrash = 0, purged = 0

            for collection in ordered {
                guard let id = collection.id else { continue }
                // D1: .never is the exemption. Safe is not special-cased — it is
                // simply seeded with .never, so a user collection set to Never
                // behaves identically.
                if case .never = collection.retention { continue }

                let doomed = try Self.evictable(db, collectionID: id, retention: collection.retention, now: now)
                guard !doomed.isEmpty else { continue }

                if collection.kind == .trash {
                    // The one place in this codebase allowed to destroy a clip.
                    try db.execute(sql: """
                        DELETE FROM clip WHERE id IN (\(doomed.map(\.description).joined(separator: ",")))
                        """)
                    purged += doomed.count
                } else {
                    try db.execute(sql: """
                        UPDATE clipCollection SET collectionID = ?, movedAt = ?
                        WHERE clipID IN (\(doomed.map(\.description).joined(separator: ",")))
                        """, arguments: [trashID, now])
                    movedToTrash += doomed.count
                }
            }

            // auto_vacuum = INCREMENTAL only marks freed pages reusable; the
            // file never actually shrinks until something runs this pragma.
            // Only a purge frees pages — a move does not — so this is gated
            // the same way. Valid inside this same write transaction: it
            // shrinks SQLite's internal page count immediately (carried over
            // from ClipStore's former `enforce`).
            if purged > 0 {
                try db.execute(sql: "PRAGMA incremental_vacuum")
            }

            return RetentionOutcome(movedToTrash: movedToTrash, purged: purged)
        }

        // The pragma above shrinks SQLite's logical page count, but our pool
        // runs WAL mode, and in WAL mode the *file on disk* is only
        // rewritten by a checkpoint (see ClipStore's former `enforce`, which
        // this behavior is carried over from). A TRUNCATE checkpoint cannot
        // run inside a write transaction ("database table is locked"), so
        // it's a separate call, gated on purged > 0 — a move frees no pages,
        // only a purge does.
        if outcome.purged > 0 {
            _ = try writer.writeWithoutTransaction { db in
                try db.checkpoint(.truncate)
            }
        }

        return outcome
    }

    // MARK: - Empty Trash

    /// Permanently deletes every clip currently filed in Trash. One of only
    /// TWO places in this codebase allowed to destroy a clip — the other is
    /// `runRetention`'s Trash-expiry purge above.
    ///
    /// Deletes everything currently filed in Trash. Empty Trash is a
    /// deliberate, confirmed action the user took while looking at Trash's
    /// actual contents — the caller (an `NSAlert`) is expected to state the
    /// true count this returns before the user confirms.
    ///
    /// Runs in ONE transaction so a failure partway never leaves Trash half
    /// emptied. Only `clip` rows are deleted directly; `clipCollection` and
    /// `clipRepresentation` rows cascade away via their FK, same as every
    /// other clip deletion in this codebase (ClipStore.delete).
    @discardableResult
    public func emptyTrash() throws -> Int {
        let deleted = try writer.write { db -> Int in
            guard let trashID = try Int64.fetchOne(db, sql: "SELECT id FROM collection WHERE kind = 'trash'")
            else { throw CollectionError.notFound }
            let ids = try Int64.fetchAll(db, sql: "SELECT clipID FROM clipCollection WHERE collectionID = ?",
                                          arguments: [trashID])
            guard !ids.isEmpty else { return 0 }
            try db.execute(sql: "DELETE FROM clip WHERE id IN (\(ids.map(\.description).joined(separator: ",")))")
            // Same reasoning as runRetention's purge: only a purge (as opposed
            // to a move) frees pages, so only a purge needs this pragma.
            try db.execute(sql: "PRAGMA incremental_vacuum")
            return ids.count
        }

        // Mirrors runRetention's checkpoint exactly: incremental_vacuum above
        // shrinks SQLite's internal page count, but in WAL mode the file on
        // disk only shrinks at a checkpoint, and a TRUNCATE checkpoint cannot
        // run inside a write transaction ("database table is locked") — so
        // it's a separate call, gated on deleted > 0.
        if deleted > 0 {
            _ = try writer.writeWithoutTransaction { db in
                try db.checkpoint(.truncate)
            }
        }

        return deleted
    }

    /// Which clips in this collection are over budget.
    private static func evictable(
        _ db: Database, collectionID: Int64, retention: Retention, now: Date
    ) throws -> [Int64] {
        switch retention {
        case .never:
            return []
        case .age(let seconds):
            return try Int64.fetchAll(db, sql: """
                SELECT cc.clipID FROM clipCollection cc
                JOIN clip ON clip.id = cc.clipID
                WHERE cc.collectionID = ? AND cc.movedAt < ?
                """, arguments: [collectionID, now.addingTimeInterval(-seconds)])
        case .length(let budget):
            // Oldest-first beyond the newest `budget` clips in this collection.
            // Kept-pinning is gone (D1): the only exemption from a collection's
            // own budget is filing elsewhere, in a .never collection like Safe.
            // Deliberately ranks by lastUsedAt, not sortKey — eviction is LRU by
            // actual use, and the two can only diverge inside never-evicted Safe
            // (spec 2026-07-21).
            return try Int64.fetchAll(db, sql: """
                SELECT cc.clipID FROM clipCollection cc
                JOIN clip ON clip.id = cc.clipID
                WHERE cc.collectionID = ?
                ORDER BY clip.lastUsedAt DESC
                LIMIT -1 OFFSET ?
                """, arguments: [collectionID, budget])
        }
    }
}

extension CollectionStore {
    // MARK: - Storage caps

    /// Bytes occupied by content NOT already in Trash. Trash content is
    /// already on its own way out via age-based purge (runRetention), so
    /// counting it here would make repeated calls to `enforceStorageCaps`
    /// keep evicting more even after the active library already fits — a
    /// move only relocates `clipCollection` rows, it does not shrink
    /// `clipRepresentation` until an actual purge runs.
    private static func activeBytes(_ db: Database, trashID: Int64) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(LENGTH(r.data)), 0)
            FROM clipRepresentation r
            JOIN clipCollection cc ON cc.clipID = r.clipID
            WHERE cc.collectionID != ?
            """, arguments: [trashID])!
    }

    /// Exposed so a caller can tell whether `enforceStorageCaps` returning 0
    /// meant "already under budget" or the skip-and-warn case (guide 5.3:
    /// nothing fails silently) — the return value alone can't say which.
    public func activeStorageBytes() throws -> Int {
        try writer.read { db in
            guard let trashID = try Int64.fetchOne(db, sql: "SELECT id FROM collection WHERE kind = 'trash'")
            else { throw CollectionError.notFound }
            return try Self.activeBytes(db, trashID: trashID)
        }
    }

    /// Trash the oldest unprotected clips until the library fits `caps.totalBytes`.
    /// Returns how many were moved.
    ///
    /// Protected = filed in a .never collection (D1). If protected content
    /// ALONE exceeds the budget we stop and return 0: purging what the user
    /// explicitly protected to satisfy a number they never set is worse than
    /// being over budget. The caller surfaces that (guide 5.3: never silent).
    @discardableResult
    public func enforceStorageCaps(_ caps: StorageCaps, now: Date = Date()) throws -> Int {
        try writer.write { db in
            guard let trashID = try Int64.fetchOne(db, sql: "SELECT id FROM collection WHERE kind = 'trash'")
            else { throw CollectionError.notFound }

            let neverIDs = try Collection.fetchAll(db)
                .filter { if case .never = $0.retention { return true } else { return false } }
                .compactMap(\.id)
            // Protected = filed in a .never collection (Safe, since user
            // collections are gone). "0" = SQL false: nothing is protected
            // if no .never collection exists.
            let protectedClause = neverIDs.isEmpty
                ? "0"
                : "cc.collectionID IN (\(neverIDs.map(\.description).joined(separator: ",")))"

            let active = try Self.activeBytes(db, trashID: trashID)
            guard active > caps.totalBytes else { return 0 }

            // Oldest-first among the unprotected, with each clip's own byte cost.
            let candidates = try Row.fetchAll(db, sql: """
                SELECT cc.clipID AS clipID, COALESCE(SUM(LENGTH(r.data)), 0) AS bytes
                FROM clipCollection cc
                JOIN clip ON clip.id = cc.clipID
                LEFT JOIN clipRepresentation r ON r.clipID = cc.clipID
                WHERE cc.collectionID != ? AND NOT (\(protectedClause))
                GROUP BY cc.clipID
                ORDER BY clip.lastUsedAt ASC
                """, arguments: [trashID])

            // `active` includes protected bytes, but `candidates` excludes
            // them — so the floor `running` can fall to is whatever's left
            // once every candidate is gone, not zero. If that floor alone
            // already busts the budget, no amount of evicting unprotected
            // clips can fix it: stop before touching anything.
            let candidateBytes = candidates.reduce(0) { $0 + ($1["bytes"] as Int) }
            let protectedBytes = active - candidateBytes
            guard protectedBytes <= caps.totalBytes else { return 0 }  // protected content alone busts it

            var running = active
            var doomed: [Int64] = []
            for row in candidates where running > caps.totalBytes {
                doomed.append(row["clipID"])
                running -= (row["bytes"] as Int)
            }
            guard !doomed.isEmpty else { return 0 }  // no unprotected clips exist at all

            try db.execute(sql: """
                UPDATE clipCollection SET collectionID = ?, movedAt = ?
                WHERE clipID IN (\(doomed.map(\.description).joined(separator: ",")))
                """, arguments: [trashID, now])
            return doomed.count
        }
    }
}

public struct StorageCaps: Sendable, Equatable {
    public var perItemBytes: Int
    public var totalBytes: Int
    /// Guide Part 4.2 — the Codex defaults, adopted: 25MB/item, 500MB total.
    public static let l2Default = StorageCaps(perItemBytes: 25 * 1_048_576,
                                              totalBytes: 524_288_000)
    public init(perItemBytes: Int, totalBytes: Int) {
        self.perItemBytes = perItemBytes
        self.totalBytes = totalBytes
    }
}

public struct RetentionOutcome: Equatable, Sendable {
    public let movedToTrash: Int
    public let purged: Int
    public static let none = RetentionOutcome(movedToTrash: 0, purged: 0)
}
