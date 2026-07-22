import Foundation
import AppKit

/// Image sizing for capture.
///
/// The thumbnail is what makes images-in-SQLite fast: list scrolling reads the
/// thumb column, so a history of 10MB screenshots never drags full-size blobs
/// through the page cache. Only the preview pane loads the real thing (spec §5).
public enum ThumbnailMaker {
    /// Spec §5. Images longer than this on their longest edge get downscaled.
    public static let maxLongestEdge: CGFloat = 8192
    public static let thumbnailLongestEdge: CGFloat = 200
    private static let thumbnailQuality: CGFloat = 0.7

    /// A small JPEG for list rows. nil if the bytes aren't a decodable image.
    public static func thumbnail(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        guard w > 0, h > 0 else { return nil }

        let scale = min(1.0, thumbnailLongestEdge / max(w, h))   // never upscale
        let target = NSSize(width: floor(w * scale), height: floor(h * scale))

        return encode(rep, to: target, as: .jpeg,
                      properties: [.compressionFactor: thumbnailQuality])
    }

    /// Downscale an oversized image. Returns nil when no downscale is needed —
    /// nil means "store the original as-is", not "failure".
    public static func downscaleIfNeeded(_ data: Data, uti: String) -> Data? {
        guard SupportedTypes.images.contains(uti),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        guard max(w, h) > maxLongestEdge else { return nil }

        let scale = maxLongestEdge / max(w, h)
        let target = NSSize(width: floor(w * scale), height: floor(h * scale))
        return encode(rep, to: target, as: .png, properties: [:])
    }

    private static func encode(
        _ rep: NSBitmapImageRep,
        to size: NSSize,
        as type: NSBitmapImageRep.FileType,
        properties: [NSBitmapImageRep.PropertyKey: Any]
    ) -> Data? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let w = Int(size.width), h = Int(size.height)

        // Draw into an explicitly-sized bitmap, NOT NSImage.lockFocus(): lockFocus
        // renders at the main screen's backingScaleFactor, so on a Retina Mac every
        // output came out 2x the requested pixels — a 4x-fatter thumbnail, and a
        // "downscale" that could exceed its own limit and grow the input.
        // Image sizing must not depend on what display happens to be attached.
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        out.size = NSSize(width: w, height: h)   // 1 point == 1 pixel

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        ctx.flushGraphics()

        return out.representation(using: type, properties: properties)
    }
}
