import Foundation
import ImageIO
import Vision

/// On-device text recognition for image clips (spec Feature 3). Classic
/// VNRecognizeTextRequest: the package floor is macOS 13 and the async
/// RecognizeTextRequest API needs 15 — same engine either way. Zero network.
public enum ImageTextRecognizer {
    /// Recognized lines joined by newlines, or nil when the image doesn't
    /// decode, recognition fails, or no text is found. Synchronous and slow
    /// (hundreds of ms at .accurate) — callers run it on a background queue.
    /// The result is clipboard-derived content: NEVER log it.
    public static func recognizeText(in imageData: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
