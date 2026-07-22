import Foundation
import GRDB

/// The hub. CaptureEngine and PasteService both go through this and never
/// talk to each other — that seam is what stops a paste from re-capturing
/// itself (spec §4).
///
/// Not an actor: GRDB's DatabaseWriter is already Sendable and thread-safe,
/// and WAL exists so readers run concurrently against one writer. An actor
/// would serialize reads that WAL is designed to parallelize.
public final class ClipStore: Sendable {
    private let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Insert a clip and its representations in one transaction.
    /// Returns the new clip's rowid.
    @discardableResult
    public func insert(_ clip: Clip, representations: [ClipRepresentation]) throws -> Int64 {
        try writer.write { db in
            var stored = clip
            try stored.insert(db)
            guard let id = stored.id else {
                throw DatabaseError(message: "clip insert produced no rowid")
            }
            for var rep in representations {
                rep.clipID = id
                try rep.insert(db)
            }
            // Every clip lives somewhere. A clip with no membership row would be
            // invisible in the tree and untouchable by retention — a leak, not a clip.
            try db.execute(sql: """
                INSERT INTO clipCollection (clipID, collectionID, movedAt)
                VALUES (?, (SELECT id FROM collection WHERE kind = 'inbox'), ?)
                """, arguments: [id, clip.createdAt])
            return id
        }
    }

    /// Newest-USED first (AMEND-1), not newest-created: re-copying a clip must
    /// surface it.
    public func recentClips(limit: Int = 200) throws -> [Clip] {
        try writer.read { db in
            try Clip
                .order(Clip.Columns.sortKey.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public enum RenameError: Error, Equatable {
        case emptyTitle
    }

    /// Rename a clip's title. `clip_ft` is external-content synchronized, so
    /// this UPDATE keeps search in sync automatically — no manual reindex. A
    /// blank title is rejected: the title is the clip's only handle in the list.
    public func rename(clipID: Int64, to newTitle: String) throws {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameError.emptyTitle }
        _ = try writer.write { db in
            try db.execute(sql: "UPDATE clip SET title = ? WHERE id = ?",
                           arguments: [trimmed, clipID])
        }
    }

    public enum EditError: Error, Equatable {
        case emptyText
    }

    /// Replace a clip's text in place. Rewrites the plainText representation,
    /// deletes any rtf/html representations (they cannot survive a plain-text
    /// edit), and refreshes title / searchText / contentHash. `kind` is derived
    /// from representations, so the Type column self-corrects with no extra
    /// write. FTS follows the UPDATE automatically (clip_ft is external-content
    /// synchronized).
    ///
    /// The stored body is the raw `newText` — only the emptiness check trims, so
    /// deliberate leading/trailing whitespace survives. The hash goes through
    /// `ClipboardMatcher.primaryHash`, identical to capture, so re-copying the
    /// new text later bumps this clip instead of creating a twin.
    public func editText(clipID: Int64, to newText: String) throws {
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditError.emptyText
        }
        let bytes = Data(newText.utf8)
        let title = Clip.makeTitle(from: newText)
        let hash = ClipboardMatcher.primaryHash(payloads: [SupportedTypes.plainText: bytes])!
        _ = try writer.write { db in
            try db.execute(sql: """
                DELETE FROM clipRepresentation
                WHERE clipID = ? AND utiIdentifier IN (?, ?)
                """, arguments: [clipID, SupportedTypes.rtf, SupportedTypes.html])
            try db.execute(sql: """
                UPDATE clipRepresentation SET data = ?
                WHERE clipID = ? AND utiIdentifier = ?
                """, arguments: [bytes, clipID, SupportedTypes.plainText])
            if db.changesCount == 0 {
                var rep = ClipRepresentation(clipID: clipID, utiIdentifier: SupportedTypes.plainText, data: bytes)
                try rep.insert(db)
            }
            try db.execute(sql: """
                UPDATE clip SET title = ?, searchText = ?, contentHash = ? WHERE id = ?
                """, arguments: [title, newText, hash, clipID])
        }
    }

    /// OCR write-back (spec Feature 3). One guarded UPDATE enforces all three
    /// spec guards: a deleted clip matches no row; a user rename changed the
    /// title so `AND title = ?` misses (rename always beats late OCR); and
    /// empty recognition returns early. `insertedTitle` is the exact generic
    /// title capture inserted — it embeds a timestamp, so it is passed, not
    /// recomputed. `clip_ft` is external-content synchronized, so search
    /// follows the UPDATE with no manual reindex — same as rename().
    @discardableResult
    public func applyRecognizedText(clipID: Int64, insertedTitle: String, text: String) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let title = Clip.makeTitle(from: trimmed)
        let searchText = String(trimmed.prefix(CaptureEngine.maxSearchTextChars))
        return try writer.write { db in
            try db.execute(sql: """
                UPDATE clip SET title = ?, searchText = ? WHERE id = ? AND title = ?
                """, arguments: [title, searchText, clipID, insertedTitle])
            return db.changesCount > 0
        }
    }

    public enum CombineError: Error, Equatable {
        case noText
    }

    /// Build a new plain-text clip by appending the given clips' text in the
    /// order given, joined by `separator`. Each clip contributes its best
    /// available text (plainText > rendered RTF > rendered HTML); clips with no
    /// text are skipped. Inserts into InBox (via `insert`) and returns the new
    /// clip's id. Throws `CombineError.noText` if no input had any text. The
    /// source clips are untouched.
    @discardableResult
    public func appendToNewClip(
        clipIDs: [Int64],
        separator: String = "\n",
        createdAt: Date = Date(),
        sourceApp: String? = nil
    ) throws -> Int64 {
        var pieces: [String] = []
        for id in clipIDs {
            if let text = Self.bestText(try representations(for: id)) {
                pieces.append(text)
            }
        }
        guard !pieces.isEmpty else { throw CombineError.noText }

        let combined = pieces.joined(separator: separator)
        let bytes = Data(combined.utf8)
        let clip = Clip(
            title: Clip.makeTitle(from: combined),
            sourceApp: sourceApp,
            createdAt: createdAt,
            lastUsedAt: createdAt,
            contentHash: ClipboardMatcher.primaryHash(payloads: [SupportedTypes.plainText: bytes])!,
            searchText: combined)
        let rep = ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.plainText, data: bytes)
        return try insert(clip, representations: [rep])
    }

    /// Best plain-text rendering of a clip's representations, or nil if none
    /// carry text (a pure image). Mirrors the preview's precedence.
    private static func bestText(_ reps: [ClipRepresentation]) -> String? {
        if let r = reps.first(where: { $0.utiIdentifier == SupportedTypes.plainText }),
           let s = String(data: r.data, encoding: .utf8) { return s }
        if let r = reps.first(where: { $0.utiIdentifier == SupportedTypes.rtf }),
           let s = PlainTextRendering.fromRTF(r.data) { return s }
        if let r = reps.first(where: { $0.utiIdentifier == SupportedTypes.html }) {
            return PlainTextRendering.fromHTML(String(data: r.data, encoding: .utf8) ?? "")
        }
        return nil
    }

    public func representations(for clipID: Int64) throws -> [ClipRepresentation] {
        try writer.read { db in
            try ClipRepresentation
                .filter(ClipRepresentation.Columns.clipID == clipID)
                .fetchAll(db)
        }
    }

    /// Thumbnails for a set of clips in ONE round trip (AMEND-8). Only the
    /// thumbnail column is read — full blobs never load to render a list.
    ///
    /// The Explorer calls this on every reload, which happens on every capture
    /// while the window is open; per-clip fetches would be N+1 against a table
    /// holding megabyte image blobs.
    public func thumbnails(for clipIDs: [Int64]) throws -> [Int64: Data] {
        guard !clipIDs.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: clipIDs.count)
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT clipID, thumbnail FROM clipRepresentation
                WHERE thumbnail IS NOT NULL AND clipID IN (\(marks))
                """, arguments: StatementArguments(clipIDs))
            return Dictionary(
                rows.map { ($0["clipID"] as Int64, $0["thumbnail"] as Data) },
                uniquingKeysWith: { first, _ in first })
        }
    }

    /// Total stored payload bytes per clip, in ONE round trip. LENGTH() reads
    /// SQLite's recorded blob length without loading the blob, so this is safe
    /// to call for a whole list on every reload — same contract as thumbnails().
    /// Sums the `data` column across a clip's representations; the thumbnail
    /// column is a separate column and never counted.
    public func byteSizes(for clipIDs: [Int64]) throws -> [Int64: Int] {
        guard !clipIDs.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: clipIDs.count)
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT clipID, SUM(LENGTH(data)) AS bytes FROM clipRepresentation
                WHERE clipID IN (\(marks)) GROUP BY clipID
                """, arguments: StatementArguments(clipIDs))
            return Dictionary(
                rows.map { ($0["clipID"] as Int64, $0["bytes"] as Int) },
                uniquingKeysWith: { first, _ in first })
        }
    }

    /// The display kind (File / Image / Text) per clip, in ONE round trip — same
    /// contract as thumbnails()/byteSizes(). Derived from which representation
    /// UTIs a clip carries; when it carries several, the highest-precedence kind
    /// wins (File > Image > Text), so a screenshot reads "Image" and a rich text
    /// copy that also carries an image reads "Image" too.
    public func kinds(for clipIDs: [Int64]) throws -> [Int64: ClipKind] {
        guard !clipIDs.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: clipIDs.count)
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT clipID, utiIdentifier FROM clipRepresentation
                WHERE clipID IN (\(marks))
                """, arguments: StatementArguments(clipIDs))
            var result: [Int64: ClipKind] = [:]
            for row in rows {
                let clipID = row["clipID"] as Int64
                let kind = ClipKind(uti: row["utiIdentifier"] as String)
                result[clipID] = result[clipID].map { max($0, kind) } ?? kind
            }
            return result
        }
    }

    public func clip(id: Int64) throws -> Clip? {
        try writer.read { db in try Clip.fetchOne(db, key: id) }
    }

    public func delete(clipID: Int64) throws {
        _ = try writer.write { db in
            try Clip.deleteOne(db, key: clipID)
        }
    }

    /// Batch permanent delete — the ⌥⌫ path (spec 2026-07-19), the newest of
    /// the explicit destruction paths beside Empty Trash and Delete
    /// Immediately. Mirrors emptyTrash: representations and clipCollection
    /// rows fall via the FK cascade; only a purge frees pages, so only a
    /// purge vacuums; and in WAL mode the file on disk only shrinks at a
    /// TRUNCATE checkpoint, which cannot run inside a write transaction.
    public func delete(clipIDs: [Int64]) throws {
        guard !clipIDs.isEmpty else { return }
        let deleted = try writer.write { db -> Int in
            try db.execute(sql: """
                DELETE FROM clip WHERE id IN (\(clipIDs.map(\.description).joined(separator: ",")))
                """)
            let changes = db.changesCount
            if changes > 0 {
                try db.execute(sql: "PRAGMA incremental_vacuum")
            }
            return changes
        }
        if deleted > 0 {
            _ = try writer.writeWithoutTransaction { db in
                try db.checkpoint(.truncate)
            }
        }
    }

    /// Move to Top (spec 2026-07-21): the user deliberately surfaced these
    /// clips, so BOTH keys bump — sortKey for the visible order, lastUsedAt
    /// so LRU eviction can never pick a clip sitting at the visual top.
    public func moveToTop(clipIDs: [Int64], now: Date = Date()) throws {
        guard !clipIDs.isEmpty else { return }
        _ = try writer.write { db in
            try db.execute(sql: """
                UPDATE clip SET sortKey = ?, lastUsedAt = ?
                WHERE id IN (\(clipIDs.map(\.description).joined(separator: ",")))
                """, arguments: [now, now])
        }
    }

    public func count() throws -> Int {
        try writer.read { db in try Clip.fetchCount(db) }
    }

    // MARK: - Dedupe

    public enum InsertOutcome: Equatable, Sendable {
        case inserted(Int64)
        case bumped(Int64)
    }

    /// Insert, unless we already hold identical content — in which case bump
    /// its lastUsedAt so it floats to the top instead of creating a twin.
    /// Copying the same thing twice should surface it, not duplicate it (spec §6).
    public func insertOrBump(_ clip: Clip, representations: [ClipRepresentation]) throws -> InsertOutcome {
        try writer.write { db in
            let existing = try Clip
                .filter(Clip.Columns.contentHash == clip.contentHash)
                // Defensive tiebreak — the hash should be unique, but if it
                // ever isn't, bump the most recently used twin (AMEND-1).
                .order(Clip.Columns.lastUsedAt.desc)
                .fetchOne(db)

            if let existing, let existingID = existing.id {
                var bumped = existing
                bumped.lastUsedAt = clip.lastUsedAt
                bumped.sortKey = clip.lastUsedAt
                try bumped.update(db)
                return .bumped(existingID)
            }

            var stored = clip
            try stored.insert(db)
            guard let id = stored.id else {
                throw DatabaseError(message: "clip insert produced no rowid")
            }
            for var rep in representations {
                rep.clipID = id
                try rep.insert(db)
            }
            // Every clip lives somewhere. A clip with no membership row would be
            // invisible in the tree and untouchable by retention — a leak, not a clip.
            try db.execute(sql: """
                INSERT INTO clipCollection (clipID, collectionID, movedAt)
                VALUES (?, (SELECT id FROM collection WHERE kind = 'inbox'), ?)
                """, arguments: [id, clip.createdAt])
            return .inserted(id)
        }
    }

    // MARK: - Search

    /// Full-text search over title and body, newest first.
    ///
    /// An unusable pattern (empty, whitespace, bare "*") returns recents rather
    /// than throwing — the search field calls this on every keystroke, and a
    /// half-typed query is normal, not an error.
    public func search(_ query: String, limit: Int = 200) throws -> [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed)
        else {
            return try recentClips(limit: limit)
        }

        return try writer.read { db in
            try Clip.fetchAll(db, sql: """
                SELECT clip.*
                FROM clip
                JOIN clip_ft ON clip_ft.rowid = clip.id
                WHERE clip_ft MATCH ?
                ORDER BY clip.sortKey DESC
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    // MARK: - Smart collections

    /// Fetch a smart collection. Each case is a WHERE clause; nothing is stored.
    ///
    /// Every case ORDERS by sortKey (spec 2026-07-21). Today/This Week still
    /// FILTER on createdAt — "captured today" is a fact about capture, but
    /// within that set the display order still follows sortKey.
    public func clips(in collection: SmartCollection, limit: Int = 500) throws -> [Clip] {
        try writer.read { db in
            switch collection {
            case .inbox, .everything:
                return try Clip
                    .order(Clip.Columns.sortKey.desc)
                    .limit(limit)
                    .fetchAll(db)

            case .today:
                let start = Calendar.current.startOfDay(for: Date())
                return try Clip
                    .filter(Clip.Columns.createdAt >= start)
                    .order(Clip.Columns.sortKey.desc)
                    .limit(limit)
                    .fetchAll(db)

            case .thisWeek:
                let cutoff = Date().addingTimeInterval(-7 * 86400)
                return try Clip
                    .filter(Clip.Columns.createdAt >= cutoff)
                    .order(Clip.Columns.sortKey.desc)
                    .limit(limit)
                    .fetchAll(db)

            case .images:
                // DISTINCT matters: a clip carrying both text and PNG has two
                // representation rows and would otherwise be listed twice.
                return try Clip.fetchAll(db, sql: """
                    SELECT DISTINCT clip.*
                    FROM clip
                    JOIN clipRepresentation r ON r.clipID = clip.id
                    WHERE r.utiIdentifier IN ('public.png', 'public.tiff', 'public.jpeg')
                    ORDER BY clip.sortKey DESC
                    LIMIT ?
                    """, arguments: [limit])
            }
        }
    }

    /// Clips filed in a user collection. Distinct from `clips(in: SmartCollection)`:
    /// smart collections are queries over all clips, user collections are membership.
    public func clips(inCollection collectionID: Int64, limit: Int = 500) throws -> [Clip] {
        try writer.read { db in
            try Clip.fetchAll(db, sql: """
                SELECT clip.* FROM clip
                JOIN clipCollection cc ON cc.clipID = clip.id
                WHERE cc.collectionID = ?
                ORDER BY clip.sortKey DESC
                LIMIT ?
                """, arguments: [collectionID, limit])
        }
    }
}

/// What a clip fundamentally is, for the Explorer's Type column. Raw values
/// order the kinds so `max` picks the most notable kind when a clip carries
/// several representations. A rich web copy (text + RTF + HTML) reads "HTML";
/// a formatted copy without HTML reads "Rich Text"; a screenshot "Image".
public enum ClipKind: Int, Comparable, Sendable {
    case text = 0
    case richText = 1
    case html = 2
    case image = 3
    case file = 4

    public init(uti: String) {
        if uti == SupportedTypes.fileURL {
            self = .file
        } else if SupportedTypes.images.contains(uti) {
            self = .image
        } else if uti == SupportedTypes.html {
            self = .html
        } else if uti == SupportedTypes.rtf {
            self = .richText
        } else {
            self = .text
        }
    }

    /// Column label.
    public var label: String {
        switch self {
        case .text: return "Text"
        case .richText: return "Rich Text"
        case .html: return "HTML"
        case .image: return "Image"
        case .file: return "File"
        }
    }

    public static func < (lhs: ClipKind, rhs: ClipKind) -> Bool { lhs.rawValue < rhs.rawValue }
}
