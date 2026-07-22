import Foundation
import Carbon.HIToolbox

/// Resolves the virtual keycode that produces "v" on the CURRENT keyboard
/// layout. 0x09 is "V" only on ANSI-QWERTY — on Dvorak it types ".", so a
/// hardcoded chord pastes the wrong key for every non-QWERTY user (Maccy's
/// 3187db9/5ce912d lineage, via the Sauce library; this is the same scan
/// without the dependency).
///
/// No isolation annotation: TIS reads live HIToolbox state; the app's only
/// call site is @MainActor (PasteService.paste → postCommandV), and tests
/// hop to main.
public enum PasteKeyResolver {
    /// kVK_ANSI_V — the fallback when the layout can't be interrogated.
    public static let ansiV: CGKeyCode = 0x09

    public static func vKeyCode() -> CGKeyCode {
        // Layouts like "Dvorak - QWERTY ⌘" switch to QWERTY while ⌘ is held —
        // and the paste chord holds ⌘, so ANSI is correct for them even
        // though a bare scan of the layout would say otherwise (Maccy #482).
        if currentLayoutName()?.hasSuffix("QWERTY ⌘") == true { return ansiV }
        return keyCode(for: "v") ?? ansiV
    }

    static func currentLayoutName() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Scan the layout's keycodes for the one whose unmodified character is
    /// `character`. 0..<128 covers every virtual keycode macOS defines.
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress
            else { return nil }
            var chars = [UniChar](repeating: 0, count: 4)
            for code in 0..<UInt16(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                let err = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys, chars.count, &length, &chars)
                if err == noErr, length > 0,
                   let scalar = Unicode.Scalar(chars[0]), Character(scalar) == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
