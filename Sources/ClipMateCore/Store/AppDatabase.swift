import Foundation
import GRDB

public enum AppDatabase {
    /// Default on-disk location. Spec §5.
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ClipMateMac", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("clips.sqlite")
    }

    public static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            // auto_vacuum writes the file header, so it must run ONLY on a
            // writable connection: DatabasePool opens its readers read-only,
            // and this pragma would throw SQLite error 8 on every read.
            // It must also run before any table exists (it's a file property,
            // otherwise a no-op needing VACUUM) — prepareDatabase on the
            // writer at creation is exactly that moment.
            // Deleting large image blobs should return pages, not leave the
            // file permanently fat.
            if !db.configuration.readonly {
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            }
            // Per-connection, and not a write — so it must stay on EVERY
            // connection. Without this the representation cascade silently
            // does nothing.
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }

    /// On-disk pool. WAL is the default journal mode for DatabasePool.
    public static func makePool(at url: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: url.path, configuration: makeConfiguration())
        try migrator.migrate(pool)
        return pool
    }

    /// In-memory queue for tests. No mocks needed anywhere.
    public static func makeInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: makeConfiguration())
        try migrator.migrate(queue)
        return queue
    }

    /// Returns false if the database is corrupt. Caller must tell the user —
    /// it is the only copy of their history (spec §9).
    public static func integrityCheck(_ reader: any DatabaseReader) throws -> Bool {
        try reader.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            return result == "ok"
        }
    }

    /// True only for errors that actually mean the file is damaged.
    ///
    /// Everything else — permissions, a full disk, a locked file, a migration
    /// bug — must NOT be treated as corruption: quarantining the user's only
    /// copy of their history over a transient or unrelated error is worse than
    /// the error itself (spec §9).
    public static func isCorruption(_ error: Error) -> Bool {
        guard let dbError = error as? DatabaseError else { return false }
        return dbError.resultCode == .SQLITE_CORRUPT || dbError.resultCode == .SQLITE_NOTADB
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_clips") { db in
            try db.create(table: "clip") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("sourceApp", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.column("contentHash", .blob).notNull()
                // AMEND-4. Retention never evicts a kept clip, and kept clips
                // don't consume the 200 budget. L1 eviction is permanent —
                // without this the 201st copy silently destroys something the
                // user cared about.
                t.column("isKept", .boolean).notNull().defaults(to: false)
            }
            // AMEND-1. Every listing and LRU eviction orders by lastUsedAt.
            try db.create(index: "clip_on_lastUsedAt", on: "clip", columns: ["lastUsedAt"])
            // Smart collections still FILTER on createdAt (captured today/this week).
            try db.create(index: "clip_on_createdAt", on: "clip", columns: ["createdAt"])
            // Dedupe looks up by hash.
            try db.create(index: "clip_on_contentHash", on: "clip", columns: ["contentHash"])

            try db.create(table: "clipRepresentation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("clipID", .integer)
                    .notNull()
                    .indexed()
                    .references("clip", onDelete: .cascade)
                t.column("utiIdentifier", .text).notNull()
                t.column("data", .blob).notNull()
                t.column("thumbnail", .blob)
            }
        }

        migrator.registerMigration("v2_fts") { db in
            // Denormalized searchable text, kept on `clip` so the FTS table can
            // be external-content and synchronized automatically.
            try db.alter(table: "clip") { t in
                t.add(column: "searchText", .text).notNull().defaults(to: "")
            }
            // TRAP: this default doesn't backfill real values — it's fine here
            // because v1_clips and v2_fts always run together on an empty DB,
            // but any future migration that adds an FTS-indexed column to a
            // table with existing rows must backfill it explicitly before the
            // synchronize() rebuild below, or those rows stay unsearchable.

            // External content: indexes text living in `clip`, doesn't store it
            // twice. synchronize() installs triggers so insert/update/delete on
            // `clip` keep the index correct with no manual bookkeeping.
            try db.create(virtualTable: "clip_ft", using: FTS5()) { t in
                t.synchronize(withTable: "clip")
                t.column("title")
                t.column("searchText")
                t.tokenizer = .unicode61()
            }
        }

        migrator.registerMigration("v3_collections") { db in
            try db.create(table: "collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                // Nesting. RESTRICT (the default): a parent with children cannot be
                // deleted out from under them.
                t.column("parentID", .integer).references("collection")
                // Spaced keys (100/200/300) so reordering rewrites one row, not N.
                t.column("sortKey", .integer).notNull()
                // NULL for user collections; a CollectionKind rawValue for the four
                // seeded ones. Never identify a system collection by row id.
                t.column("kind", .text)
                t.column("retentionType", .text).notNull()
                // Count for .length, seconds for .age, ignored for .never.
                t.column("retentionValue", .integer).notNull()
            }
            // Partial unique index: one row per system kind, unlimited NULL user rows.
            try db.create(index: "collection_on_kind", on: "collection",
                          columns: ["kind"], unique: true, condition: Column("kind") != nil)
            try db.create(index: "collection_on_parentID", on: "collection", columns: ["parentID"])

            // clipID as PRIMARY KEY is what enforces one-collection-per-clip; it needs
            // no separate unique index. ON DELETE CASCADE means deleting a clip can
            // never leave an orphan membership row.
            //
            // The collectionID FK is deliberately RESTRICT, not CASCADE: deleting a
            // collection that still holds clips must FAIL LOUDLY rather than take the
            // user's clips with it. CollectionStore.delete empties it first.
            try db.create(table: "clipCollection") { t in
                t.primaryKey("clipID", .integer).references("clip", onDelete: .cascade)
                t.column("collectionID", .integer).notNull().references("collection")
                // When the clip entered THIS collection. Drives Trash's grace period
                // and Overflow's age retention — one column, both jobs.
                t.column("movedAt", .datetime).notNull()
            }
            try db.create(index: "clipCollection_on_collection", on: "clipCollection",
                          columns: ["collectionID", "movedAt"])

            func seed(_ name: String, _ kind: String, _ sortKey: Int, _ type: String, _ value: Int) throws {
                try db.execute(sql: """
                    INSERT INTO collection (name, sortKey, kind, retentionType, retentionValue)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [name, sortKey, kind, type, value])
            }
            // InBox's 200 is L1's RetentionPolicy.l1Default, preserved so the upgrade
            // changes where clips go, not how many survive.
            try seed("InBox", "inbox", 100, "length", 200)
            try seed("Overflow", "overflow", 200, "length", 800)
            try seed("Trash", "trash", 300, "age", 604_800)   // 7 days
            try seed("Safe", "safe", 400, "never", 0)

            // Backfill: every clip that predates collections belongs in InBox.
            // movedAt = lastUsedAt, not now() — a clip that has sat untouched for a
            // month must not look freshly filed, or the cascade's ordering lies.
            try db.execute(sql: """
                INSERT INTO clipCollection (clipID, collectionID, movedAt)
                SELECT clip.id, (SELECT id FROM collection WHERE kind = 'inbox'), clip.lastUsedAt
                FROM clip
                """)
        }

        migrator.registerMigration("v4_sourceURL") { db in
            // Metadata, not searchable content: NOT an FTS-indexed column, so no
            // backfill/rebuild is needed (contrast the v2_fts trap note above).
            try db.alter(table: "clip") { t in
                t.add(column: "sourceURL", .text)
            }
        }

        // Safe + retention-sweep tranche F3: the Trash grace drops from 7
        // days to 6. The value lives in the user's collection row, so this
        // is data, not schema — and the v3 seed is NOT edited (recorded
        // migrations are append-only). Fresh databases seed 7 days in v3 and
        // convert here in the same migrator pass: one code path for old and
        // new DBs. Guarded on the old default so a user-customized retention
        // is never clobbered; the guard also makes it idempotent.
        migrator.registerMigration("v5_trash_six_days") { db in
            try db.execute(sql: """
                UPDATE collection SET retentionValue = 518400
                WHERE kind = 'trash' AND retentionType = 'age' AND retentionValue = 604800
                """)
        }

        // Overflow-removal tranche: the middle cascade bucket is gone. InBox
        // absorbs its capacity (200 + 800 = 1,000) and cascades straight to
        // Trash. Three ordered statements, one migration:
        //   1. Members merge into InBox with movedAt PRESERVED — a bucket
        //      merge is not a user action, so clips keep their age and their
        //      cascade order. (Merged clips are by construction older than
        //      InBox residents, so an over-1,000 merge trims exactly the
        //      clips that were already nearest to Trash.)
        //   2. The cap update is guarded on the shipped default, v5-style: a
        //      user-customized InBox cap is never clobbered. Idempotent.
        //   3. The row is deleted LAST — clipCollection.collectionID's FK
        //      (default NO ACTION) refuses to drop a collection that still
        //      has members, so a wrong order fails loudly here rather than
        //      corrupting silently. The row MUST go: with the enum case
        //      removed, a surviving kind='overflow' row would decode kind as
        //      nil and masquerade as a user collection named "Overflow".
        // Fresh databases still run the v3 seed and get reshaped here in the
        // same migrator pass: one code path for old and new DBs.
        migrator.registerMigration("v6_remove_overflow") { db in
            try db.execute(sql: """
                UPDATE clipCollection
                SET collectionID = (SELECT id FROM collection WHERE kind = 'inbox')
                WHERE collectionID = (SELECT id FROM collection WHERE kind = 'overflow')
                """)
            try db.execute(sql: """
                UPDATE collection SET retentionValue = 1000
                WHERE kind = 'inbox' AND retentionType = 'length' AND retentionValue = 200
                """)
            try db.execute(sql: "DELETE FROM collection WHERE kind = 'overflow'")
        }

        migrator.registerMigration("v7_remove_user_collections") { db in
            // User collections are exactly the kind IS NULL rows; system rows
            // always carry a kind (v3's partial unique index enforces one each).
            try db.execute(sql: """
                UPDATE clipCollection SET collectionID = (SELECT id FROM collection WHERE kind = 'inbox')
                WHERE collectionID IN (SELECT id FROM collection WHERE kind IS NULL)
                """)
            try db.execute(sql: "DELETE FROM collection WHERE kind IS NULL")
        }

        migrator.registerMigration("v8_sort_key") { db in
            // Display order becomes explicitly manipulable (bottom-of-Safe, Move to
            // Top) without faking lastUsedAt, which the UI shows as a date. Not
            // FTS-indexed, so the v2 backfill trap does not apply. NOT NULL needs a
            // constant default; the backfill overwrites it on every existing row,
            // and the model sets it on every insert.
            try db.alter(table: "clip") { t in
                t.add(column: "sortKey", .datetime).notNull().defaults(to: Date(timeIntervalSince1970: 0))
            }
            try db.execute(sql: "UPDATE clip SET sortKey = lastUsedAt")
            try db.create(index: "clip_on_sortKey", on: "clip", columns: ["sortKey"])
        }

        return migrator
    }
}
