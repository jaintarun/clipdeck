import Foundation
import GRDB

/// One representation of a clip's payload.
///
/// NSPasteboard genuinely returns several representations per item — copy from
/// Safari and you get plain text AND HTML AND RTF for one copy. This is the
/// platform's model, which is why this is a separate table rather than a
/// `content: String` column on Clip.
public struct ClipRepresentation: Codable, Equatable, Sendable {
    public var id: Int64?
    public var clipID: Int64
    /// UTType identifier, e.g. "public.utf8-plain-text", "public.png".
    /// Stored as its String identifier; UTType itself is not a DatabaseValue.
    public var utiIdentifier: String
    public var data: Data
    /// ~200px JPEG. Images only; nil for text.
    /// List scrolling reads this so full-size blobs never hit the page cache.
    public var thumbnail: Data?

    public init(
        id: Int64? = nil,
        clipID: Int64,
        utiIdentifier: String,
        data: Data,
        thumbnail: Data? = nil
    ) {
        self.id = id
        self.clipID = clipID
        self.utiIdentifier = utiIdentifier
        self.data = data
        self.thumbnail = thumbnail
    }
}

extension ClipRepresentation: TableRecord, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "clipRepresentation"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let clipID = Column(CodingKeys.clipID)
        public static let utiIdentifier = Column(CodingKeys.utiIdentifier)
        public static let data = Column(CodingKeys.data)
        public static let thumbnail = Column(CodingKeys.thumbnail)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
