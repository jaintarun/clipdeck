import AppKit
import ClipMateCore

/// The paste-fidelity setting (spec Feature 1). UserDefaults, not the
/// database: a preference, not history — same reasoning as HotkeyPreference.
/// Default is PLAIN: the user asked for "paste without formatting so I don't
/// have to do anything"; ⌥ at the moment of the action inverts.
enum PastePreference {
    static let plainByDefaultKey = "pastePlainByDefault"

    static var plainByDefault: Bool {
        UserDefaults.standard.object(forKey: plainByDefaultKey) as? Bool ?? true
    }

    /// Resolve fidelity for an action happening RIGHT NOW. Reads the live
    /// hardware modifier state (`NSEvent.modifierFlags`), so it works
    /// identically for Enter, double-click, and menu clicks. Call it
    /// synchronously at the action site — never inside a later Task, where ⌥
    /// may already be released.
    @MainActor
    static func currentFidelity() -> PasteFidelity {
        PasteFidelity.resolve(plainByDefault: plainByDefault,
                              optionHeld: NSEvent.modifierFlags.contains(.option))
    }
}
