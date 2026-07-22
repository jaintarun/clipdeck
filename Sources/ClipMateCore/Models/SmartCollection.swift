import Foundation

/// The L1 sidebar. Each case is a query, not a stored row — which is why L1
/// has no `collections` table (spec §5).
///
/// ClipMate implemented this by stuffing a SQL string into a column. We use an
/// enum instead: same behaviour, no SQL injection surface, and the compiler
/// checks it.
public enum SmartCollection: String, CaseIterable, Sendable, Identifiable {
    case inbox
    case today
    case thisWeek
    case images
    case everything

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox:      return "InBox"
        case .today:      return "Today"
        case .thisWeek:   return "This Week"
        case .images:     return "Images"
        case .everything: return "Everything"
        }
    }

    public var systemImageName: String {
        switch self {
        case .inbox:      return "tray"
        case .today:      return "clock"
        case .thisWeek:   return "calendar"
        case .images:     return "photo"
        case .everything: return "asterisk"
        }
    }

    /// Shown in the sidebar. InBox is the only one with a retention rule in L1.
    public var retentionBadge: String? {
        switch self {
        case .inbox: return "200"
        default:     return nil
        }
    }
}
