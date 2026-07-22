import Foundation
import GRDB

/// One captured clipboard event. Carries 1..N representations (see ClipRepresentation).
public struct Clip: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    /// Derived for display: first non-empty line, truncated.
    public var title: String
    /// Bundle ID of the frontmost app at capture time.
    /// Heuristic — we sample up to one poll interval after the copy. Display only.
    public var sourceApp: String?
    /// When first captured. FILTERS Today / This Week — never orders lists.
    public var createdAt: Date
    /// When last captured or re-copied. ORDERS every list and drives LRU
    /// eviction (AMEND-1). Re-copying a clip must float it to the top, and a
    /// clip you use daily must not be evicted for having been *created* long
    /// ago.
    public var lastUsedAt: Date
    /// Display position: every list ORDERS BY sortKey DESC. Usually equals
    /// lastUsedAt (capture and bump set both), diverging only through the two
    /// explicit gestures: Move to Top (both = now) and move-to-Safe (sortKey
    /// drops below Safe's floor; lastUsedAt untouched). Eviction still ranks
    /// by lastUsedAt — the orders can only differ inside never-evicted Safe.
    public var sortKey: Date
    /// SHA-256 over the payload bytes. Used for dedupe.
    public var contentHash: Data
    /// Full text used for search. For text clips this is the whole payload;
    /// for images it is the title. Denormalized so FTS5 can external-content
    /// index it without a join.
    public var searchText: String
    /// The web URL a copy carried (`public.url`), when present and http(s).
    /// Display/open only — never dedupes, never pastes, never logged.
    public var sourceURL: String?

    public init(
        id: Int64? = nil,
        title: String,
        sourceApp: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        sortKey: Date? = nil,
        contentHash: Data,
        searchText: String = "",
        sourceURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sortKey = sortKey ?? lastUsedAt
        self.contentHash = contentHash
        self.searchText = searchText
        self.sourceURL = sourceURL
    }
}

extension Clip: TableRecord, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "clip"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let title = Column(CodingKeys.title)
        public static let sourceApp = Column(CodingKeys.sourceApp)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let lastUsedAt = Column(CodingKeys.lastUsedAt)
        public static let sortKey = Column(CodingKeys.sortKey)
        public static let contentHash = Column(CodingKeys.contentHash)
        public static let searchText = Column(CodingKeys.searchText)
        public static let sourceURL = Column(CodingKeys.sourceURL)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Clip {
    /// First non-empty line, trimmed and truncated. Display only.
    public static func makeTitle(from text: String, limit: Int = 120) -> String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return "(empty)" }
        return line.count <= limit ? line : String(line.prefix(limit)) + "…"
    }
}
