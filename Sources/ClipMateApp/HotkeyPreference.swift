import Foundation
import Carbon.HIToolbox

/// Which key summons the panel.
///
/// UserDefaults, not the database: a preference, not history, and it must
/// survive the database being wiped after corruption (same reasoning as
/// BlocklistStore).
///
/// L1.5 ships storage only — no recorder UI until the L2 Settings window.
/// Until then it is reachable with:
///   defaults write com.clipmateclone.app hotkeyKeyCode -int 9
///   defaults write com.clipmateclone.app hotkeyModifiers -int 6400
/// where 6400 == controlKey|optionKey|cmdKey (4096|2048|256) — Carbon's
/// modifier bits, not NSEvent's.
enum HotkeyPreference {
    private static let keyCodeKey = "hotkeyKeyCode"
    private static let modifiersKey = "hotkeyModifiers"

    /// ⌃⌥⌘V — spec §11.3. kVK_ANSI_V == 0x09.
    static let defaultKeyCode: UInt32 = 0x09
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)

    /// The stored pair, or the default.
    ///
    /// `UserDefaults.integer(forKey:)` returns 0 for a missing key, and 0 is
    /// also a real keyCode ('a') — but a hotkey with no modifiers would steal
    /// a bare keypress system-wide, so treat either zero as "unset" rather
    /// than registering something the user never asked for.
    static var current: (keyCode: UInt32, modifiers: UInt32) {
        let d = UserDefaults.standard
        let code = d.integer(forKey: keyCodeKey)
        let mods = d.integer(forKey: modifiersKey)
        guard code > 0, mods > 0 else { return (defaultKeyCode, defaultModifiers) }
        return (UInt32(code), UInt32(mods))
    }

    static func save(keyCode: UInt32, modifiers: UInt32) {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: keyCodeKey)
        d.set(Int(modifiers), forKey: modifiersKey)
    }

    static func reset() {
        let d = UserDefaults.standard
        d.removeObject(forKey: keyCodeKey)
        d.removeObject(forKey: modifiersKey)
    }
}
