import Foundation
import GRDB

/// Which collection a clip is filed in. Exactly one row per clip — enforced by
/// `clipID` being the primary key, not by application code.
public struct ClipCollection: Codable, Equatable, Sendable {
    public var clipID: Int64
    public var collectionID: Int64
    /// When the clip entered this collection. Reset on every move, because the
    /// cascade's grace periods measure time-in-collection, not age-of-clip.
    public var movedAt: Date

    public init(clipID: Int64, collectionID: Int64, movedAt: Date = Date()) {
        self.clipID = clipID
        self.collectionID = collectionID
        self.movedAt = movedAt
    }
}

extension ClipCollection: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "clipCollection"
    public enum Columns {
        public static let clipID = Column(CodingKeys.clipID)
        public static let collectionID = Column(CodingKeys.collectionID)
        public static let movedAt = Column(CodingKeys.movedAt)
    }
}
