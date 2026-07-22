import Foundation

/// Bundle IDs the user never wants captured (spec §13 step 5).
///
/// UserDefaults, not the database: this is a preference, not history, and it
/// must survive the database being wiped after corruption.
enum BlocklistStore {
    private static let key = "blockedBundleIDs"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(ids.sorted(), forKey: key)
    }
}
