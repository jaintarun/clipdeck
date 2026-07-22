import Foundation
import AppKit
import Carbon.HIToolbox   // IsSecureEventInputEnabled lives here, not in AppKit

public enum PasteError: Error, Equatable {
    case accessibilityDenied
    case secureInputActive
    case noTarget
    case targetGone
    case activationTimedOut
    case nothingToPaste
    case targetHijacked
}

/// Writes a clip to the pasteboard and synthesizes Cmd+V into the target app.
///
/// PROVEN by spike/paste_spike.swift on 2026-07-16: CGEvent Cmd+V into TextEdit,
/// verified by reading the text back through the AX API.
///
/// Knows nothing about CaptureEngine. Both go through ClipStore.
public final class PasteService {
    private let store: ClipStore
    private let tracker: TargetTracker

    public init(store: ClipStore, tracker: TargetTracker) {
        self.store = store
        self.tracker = tracker
    }

    // MARK: - Permissions

    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    public static func requestAccessibility() {
        // `kAXTrustedCheckOptionPrompt` itself is a global CFStringRef Swift 6
        // flags as concurrency-unsafe shared mutable state. Its value is the
        // documented, stable constant "AXTrustedCheckOptionPrompt" (Apple's
        // own headers/samples), so the literal sidesteps the diagnostic
        // without changing behavior.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// When a password field has focus macOS enables secure input and SILENTLY
    /// drops synthesized keys. Detectable — so we can tell the user why their
    /// paste vanished instead of leaving them confused (spec §7).
    public static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    // MARK: - Pasteboard

    /// Put a clip on the pasteboard, stamped as ours so CaptureEngine ignores
    /// it. This is the guard that stops the history eating itself.
    ///
    /// Main-actor confined: NSPasteboard is not documented thread-safe, and
    /// clear → write representations → write the ownership marker is three
    /// separate mutations that must not interleave with CaptureEngine's
    /// polling (also main-confined) — an interleaving could observe our
    /// content before the marker lands and re-capture it as a new clip.
    @MainActor
    public func copyToPasteboard(clipID: Int64, fidelity: PasteFidelity = .full) throws {
        let reps = try store.representations(for: clipID)
        let stored = reps.filter { SupportedTypes.all.contains($0.utiIdentifier) }
        guard !stored.isEmpty else { throw PasteError.nothingToPaste }
        // Feature 1: the emission planner decides what this paste writes.
        // File and image clips come back whole in both modes, so the fileURL
        // branch below is unaffected by fidelity.
        let supported = PasteEmission.representations(for: stored, fidelity: fidelity)

        let pb = NSPasteboard.general

        // File clips go back as real pasteboard items so Finder pastes FILES,
        // not the words. Measured: writeObjects makes one item per URL and
        // macOS synthesizes NSFilenamesPboardType + "Apple URL pasteboard
        // type" alongside — the same shape Finder's own ⌘C produces.
        let urls = supported.first(where: { $0.utiIdentifier == SupportedTypes.fileURL })
            .map { FileClip.decode($0.data) }

        // Must run before clearContents below, not after: if a stored file
        // clip ever decoded to zero URLs, clearing first and only then
        // throwing would wipe the user's real clipboard on a failure path
        // nobody asked us to touch.
        guard urls?.isEmpty != true else { throw PasteError.nothingToPaste }

        pb.clearContents()

        if let urls {
            pb.writeObjects(urls.map { $0 as NSURL })

            // Finder puts the filenames on item 0 as text too; matching that
            // means pasting a file clip into a text editor still gives names.
            if let textRep = supported.first(where: { $0.utiIdentifier == SupportedTypes.plainText }) {
                pb.setData(textRep.data, forType: NSPasteboard.PasteboardType(SupportedTypes.plainText))
            }
        } else {
            for rep in supported {
                pb.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.utiIdentifier))
            }
        }

        // Measured: this still lands, and stays readable, after writeObjects.
        // If it ever stopped landing, pasting a file clip would be re-captured
        // and the history would eat itself — which is what the loop test guards.
        pb.setData(Data([1]), forType: NSPasteboard.PasteboardType(PasteboardMarkers.ownership))
    }

    // MARK: - Paste

    /// Paste a clip into the app the user was last in.
    ///
    /// AMEND-7: the pasteboard write happens FIRST, before any guard. If we
    /// can't auto-paste, the user should at least be holding the clip — every
    /// error path below can then honestly say "it's on your clipboard, press
    /// ⌘V". Guarding first would leave a denied paste doing nothing at all.
    @MainActor
    public func paste(clipID: Int64, fidelity: PasteFidelity = .full) async throws {
        try copyToPasteboard(clipID: clipID, fidelity: fidelity)

        // Pasting deliberately does NOT reorder the list (user decision
        // 2026-07-18, reversing Maccy G13): picking an old clip must leave it
        // where the user found it. Only a fresh COPY floats a clip, via
        // insertOrBump's dedupe path.

        guard Self.isAccessibilityTrusted else { throw PasteError.accessibilityDenied }
        guard !Self.isSecureInputActive else { throw PasteError.secureInputActive }
        guard let target = tracker.current else { throw PasteError.noTarget }
        guard !target.isTerminated else { throw PasteError.targetGone }

        target.activate()
        try await waitForActivation(of: target)

        // Re-check here, not just at entry: activating another app is
        // exactly what can raise a login window or re-auth prompt, which
        // can flip secure input ON during the wait above. macOS then
        // silently drops the synthesized keys, so this is not redundant
        // with the entry check — the entry check fails fast before we
        // activate anything; this one catches state that changed *because*
        // of that activation.
        guard !Self.isSecureInputActive else { throw PasteError.secureInputActive }

        // The wait above cannot be relied on to have checked anything: on the
        // QuickPanel path the panel is nonactivating, so the target never
        // stopped being active and waitForActivation's loop body never ran.
        // Its settle sleep is still a real window for focus to move, and
        // postCommandV posts to whoever holds focus — not to a pid. So confirm
        // the target is STILL the one listening, right before we type into it.
        guard target.isActive else { throw PasteError.targetHijacked }

        postCommandV()
    }

    /// Wait until the target is really frontmost.
    ///
    /// NEVER sleep a constant here. activate() is async: the spike found a
    /// paste at 0ms is silently LOST while 50ms lands — but that 50ms was one
    /// run, on an idle machine, into TextEdit. A loaded machine or an Electron
    /// app can need more, so any fixed constant is a number that fails on
    /// someone's machine (spec §7).
    @MainActor
    private func waitForActivation(
        of app: NSRunningApplication,
        timeout: TimeInterval = 1.0
    ) async throws {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        while !app.isActive {
            if app.isTerminated { throw PasteError.targetGone }

            // Abort the moment focus lands somewhere we did not ask for — a
            // notification, Spotlight, a login window. Riding out the timeout
            // risks posting ⌘V into whatever is frontmost by then (Codex §8.3).
            //
            // Our own app is expected here: on the Explorer-window path
            // ClipMate activates itself before the target does, so ClipMate
            // being briefly frontmost is not a hijack. A nil frontmost app is
            // expected too — there is a real instant during a switch when
            // nothing is frontmost.
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != app.processIdentifier,
               front.processIdentifier != ourPID {
                throw PasteError.targetHijacked
            }

            if Date() >= deadline { throw PasteError.activationTimedOut }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // One frame of settle after activation is confirmed: being frontmost
        // and having installed the key handler are not the same instant.
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func postCommandV() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        // A fast typist's in-flight keys can interleave with the synthetic
        // chord; suppress local keyboard events for the interval (Maccy G6).
        src.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        // Layout-aware: 0x09 is "V" only on ANSI-QWERTY (Maccy G5).
        let vCode = PasteKeyResolver.vKeyCode()
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vCode, keyDown: false)
        else { return }
        // 0x000008 is the device-dependent "left modifier" bit. RDP's
        // scan-code mode silently drops the paste without it (Flycut PR #18,
        // carried by Maccy ever since).
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        down.flags = flags
        up.flags = flags
        // .cgSessionEventTap is the tap every shipping clipboard manager
        // posts to (Maccy/Clipy/Flycut) — the annotated variant is not what
        // the ecosystem has field-tested.
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}

extension PasteError {
    /// Shown to the user verbatim. Silence is the enemy (spec §9).
    public var userMessage: String {
        switch self {
        // Every message below can promise the clipboard truthfully: paste()
        // writes the pasteboard before any guard runs (AMEND-7).
        case .accessibilityDenied:
            return "ClipDeck needs Accessibility permission to paste for you. "
                 + "The clip is on your clipboard — press ⌘V."
        case .secureInputActive:
            return "Another app has secure input enabled (usually a focused password field), "
                 + "so macOS is blocking the paste. The clip is on your clipboard — press ⌘V."
        case .noTarget:
            return "ClipDeck couldn't tell which app to paste into. "
                 + "The clip is on your clipboard — press ⌘V."
        case .targetGone:
            return "The app you were pasting into has quit. "
                 + "The clip is on your clipboard — press ⌘V."
        case .activationTimedOut:
            return "The target app didn't come to the front in time. The clip is on your clipboard — press ⌘V."
        case .nothingToPaste:
            return "That clip has no content to paste."
        case .targetHijacked:
            return "Another app took focus before the paste could land, so ClipDeck stopped "
                 + "rather than paste into the wrong place. The clip is on your clipboard — press ⌘V."
        }
    }
}
