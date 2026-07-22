import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon's RegisterEventHotKey. Still the only supported way
/// to get a system-wide hotkey without an event tap (which would need
/// Accessibility just to listen).
///
/// @MainActor: constructed/torn down only from AppDelegate on the main thread,
/// and Carbon delivers hotkey-pressed events through the app's main event
/// loop. The event handler itself is a C function pointer, which carries no
/// isolation the compiler can see, so it asserts the invariant with
/// MainActor.assumeIsolated rather than reaching for nonisolated(unsafe) —
/// same pattern AppDelegate already uses for engine.onResult.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler
        Self.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C4D54), id: id)  // 'CLMT'
        let status = RegisterEventHotKey(
            keyCode, modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            Self.handlers[id] = nil
            return nil
        }
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            MainActor.assumeIsolated {
                HotKey.handlers[hkID.id]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    // isolated deinit (SE-0371): unregister() touches MainActor-isolated
    // state (`ref`, the static `handlers` table), and ARC does not otherwise
    // guarantee deinit runs on the actor that isolates the class.
    isolated deinit { unregister() }
}
