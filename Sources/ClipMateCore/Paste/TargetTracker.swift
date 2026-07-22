import Foundation
import AppKit

/// Remembers the last app that wasn't us.
///
/// Must know the target BEFORE our panel appears — asking afterwards is too
/// late, because by then we are frontmost (spec §7).
///
/// `@unchecked Sendable`: `NSWorkspace`'s block-based `addObserver` requires a
/// `@Sendable` closure regardless of the `queue: .main` argument, which the
/// type system can't see. Same shape as `CaptureEngine`'s `Timer` callback
/// (Task 5) — main-thread affinity is real but enforced by convention, not
/// by the type system.
public final class TargetTracker: @unchecked Sendable {
    public private(set) var current: NSRunningApplication?
    private var observer: NSObjectProtocol?

    public init() {
        current = NSWorkspace.shared.frontmostApplication
    }

    public func start() {
        stop()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            // Never track ourselves — we'd paste into our own panel.
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.current = app
        }
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    deinit { stop() }
}
