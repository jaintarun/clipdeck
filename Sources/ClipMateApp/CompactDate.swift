import Foundation

/// "Jul 17, 11:24 PM" (same year) / "Jul 17, 2025, 11:24 PM" (other year).
/// Composed from cached template formatters so no locale inserts " at ", and
/// the list's Date column fits its 150pt budget. Absolute timestamps by the
/// user's explicit earlier call — never "2 hr. ago" in the Explorer.
@MainActor
enum CompactDate {
    private static let day = template("MMMd")
    private static let dayYear = template("yMMMd")
    private static let time = template("jmm")

    static func string(from date: Date) -> String {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        let dayPart = (sameYear ? day : dayYear).string(from: date)
        return "\(dayPart), \(time.string(from: date))"
    }

    private static func template(_ t: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(t)
        return f
    }
}
