import Foundation

/// Trailing-edge debounce for keystroke-driven work. Each call cancels the
/// pending one; the block runs after `delay` of quiet. Search fields use this
/// so a burst of typing costs ONE query, not one per keystroke — the exact
/// mechanism behind Maccy's search dying at ~2k items (G7).
@MainActor
public final class Debouncer {
    private let delay: Duration
    private var pending: Task<Void, Never>?

    public init(delay: Duration) {
        self.delay = delay
    }

    public func call(_ block: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            block()
        }
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
    }
}
