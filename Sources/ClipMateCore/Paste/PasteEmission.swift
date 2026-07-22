import Foundation

/// What a paste writes to the pasteboard (spec Feature 1).
public enum PasteFidelity: Equatable, Sendable {
    case plain
    case full

    /// The one rule: ⌥ inverts whichever default is set. No third state.
    public static func resolve(plainByDefault: Bool, optionHeld: Bool) -> PasteFidelity {
        (plainByDefault != optionHeld) ? .plain : .full
    }
}

/// Decides exactly which representations a paste emits. Pure — no pasteboard,
/// so the whole matrix is unit-testable.
public enum PasteEmission {
    /// `.full` is a passthrough. `.plain` keeps only plain text, synthesizing
    /// it from RTF/HTML (local renderers — the no-web-engine floor holds) when
    /// the clip has no plain-text rep. Exempt in both modes: file clips
    /// (Maccy #962 — stripping formatting must never drop files) and image
    /// clips (a "plain" image is nothing). Never returns an empty list for a
    /// non-empty input: when nothing renders, it falls back to `.full`.
    public static func representations(
        for reps: [ClipRepresentation], fidelity: PasteFidelity
    ) -> [ClipRepresentation] {
        guard fidelity == .plain else { return reps }
        let hasFile = reps.contains { $0.utiIdentifier == SupportedTypes.fileURL }
        let hasImage = reps.contains { SupportedTypes.images.contains($0.utiIdentifier) }
        guard !hasFile, !hasImage else { return reps }

        if let plain = reps.first(where: { $0.utiIdentifier == SupportedTypes.plainText }) {
            return [plain]
        }
        if let rtf = reps.first(where: { $0.utiIdentifier == SupportedTypes.rtf }),
           let text = PlainTextRendering.fromRTF(rtf.data),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [ClipRepresentation(clipID: rtf.clipID,
                                       utiIdentifier: SupportedTypes.plainText,
                                       data: Data(text.utf8))]
        }
        if let html = reps.first(where: { $0.utiIdentifier == SupportedTypes.html }) {
            let text = PlainTextRendering.fromHTML(String(data: html.data, encoding: .utf8) ?? "")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [ClipRepresentation(clipID: html.clipID,
                                           utiIdentifier: SupportedTypes.plainText,
                                           data: Data(text.utf8))]
            }
        }
        return reps
    }
}
