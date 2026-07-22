import Foundation
import GRDB

/// What a collection does to clips that sit in it for too long.
///
/// Replaces L1's global `RetentionPolicy`: retention is a property of a
/// collection, not of the app.
public enum Retention: Equatable, Sendable {
    /// Keep the N newest; the oldest beyond that cascade onward.
    case length(Int)
    /// Cascade anything that entered this collection longer ago than this.
    case age(TimeInterval)
    /// Never purge. Safe is simply a seeded collection with this setting —
    /// a user collection set to .never is exactly as safe as Safe.
    case never

    var storedType: String {
        switch self {
        case .length: "length"
        case .age: "age"
        case .never: "never"
        }
    }

    var storedValue: Int {
        switch self {
        case .length(let n): n
        case .age(let seconds): Int(seconds)
        case .never: 0
        }
    }

    /// Returns nil for an unrecognized type rather than trapping: a row written
    /// by a future version must not crash this one.
    static func decode(type: String, value: Int) -> Retention? {
        switch type {
        case "length": .length(value)
        case "age": .age(TimeInterval(value))
        case "never": .never
        default: nil
        }
    }
}

/// The three collections the app creates and depends on. User collections have
/// no kind. Identify system collections by this, never by row id. (Overflow
/// existed through v5 and was removed by the v6 migration — a clip is either
/// in the library or in Trash, nothing in between.)
public enum CollectionKind: String, Sendable, CaseIterable {
    case inbox, trash, safe
}

public struct Collection: Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var name: String
    public var parentID: Int64?
    public var sortKey: Int
    public var kind: CollectionKind?
    public var retention: Retention

    public init(
        id: Int64? = nil,
        name: String,
        parentID: Int64? = nil,
        sortKey: Int,
        kind: CollectionKind? = nil,
        retention: Retention
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortKey = sortKey
        self.kind = kind
        self.retention = retention
    }

    /// A system collection is the app's furniture: it cannot be renamed or
    /// deleted, and the UI must not offer to.
    public var isSystem: Bool { kind != nil }
}

// Hand-written rather than Codable: `retention` is one Swift value stored as
// two columns, which no synthesized coding can express.
extension Collection: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "collection"

    public enum Columns {
        public static let id = Column("id")
        public static let name = Column("name")
        public static let parentID = Column("parentID")
        public static let sortKey = Column("sortKey")
        public static let kind = Column("kind")
        public static let retentionType = Column("retentionType")
        public static let retentionValue = Column("retentionValue")
    }

    public init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        parentID = row["parentID"]
        sortKey = row["sortKey"]
        kind = (row["kind"] as String?).flatMap(CollectionKind.init(rawValue:))
        // An unreadable retention is a corrupt row, not a crash: fall back to
        // .never so the worst case keeps the user's clips rather than purging
        // them on a value we failed to understand.
        retention = Retention.decode(type: row["retentionType"], value: row["retentionValue"]) ?? .never
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["parentID"] = parentID
        container["sortKey"] = sortKey
        container["kind"] = kind?.rawValue
        container["retentionType"] = retention.storedType
        container["retentionValue"] = retention.storedValue
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
