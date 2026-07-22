import Foundation
import Testing
@testable import ClipMateCore

@Suite("PasteKeyResolver")
struct PasteKeyResolverTests {

    /// TIS reads the live layout, so the strong assertion only holds on
    /// QWERTY-family layouts (which dev/CI machines are). On anything else the
    /// resolver must still return a valid code — that's the whole point.
    @MainActor
    @Test("resolves the V key for the current layout")
    func resolvesV() {
        let code = PasteKeyResolver.vKeyCode()
        #expect(code < 128)

        let name = PasteKeyResolver.currentLayoutName() ?? ""
        if ["U.S.", "ABC", "British", "QWERTY"].contains(where: { name.contains($0) }) {
            #expect(code == PasteKeyResolver.ansiV)
        }
    }

    @MainActor
    @Test("a character no key produces resolves to nil (the fallback's trigger)")
    func unresolvableCharacterIsNil() {
        #expect(PasteKeyResolver.keyCode(for: "☃") == nil)
    }
}
