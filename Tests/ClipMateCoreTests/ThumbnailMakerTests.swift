import Foundation
import AppKit
import Testing
@testable import ClipMateCore

@Suite("ThumbnailMaker")
struct ThumbnailMakerTests {

    /// Build a real PNG at an exact pixel size, so we're testing actual image
    /// code, not a stub. Draws into an explicitly-sized NSBitmapImageRep
    /// rather than NSImage.lockFocus(), which renders at the screen's
    /// backingScaleFactor — the same flaw ThumbnailMaker.encode() had. A
    /// fixture built with lockFocus would silently double on any Retina
    /// display, which is exactly what hid the production bug.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ctx = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.current = ctx
        NSColor.systemBlue.drawSwatch(in: NSRect(x: 0, y: 0, width: width, height: height))
        ctx.flushGraphics()

        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test("a thumbnail is produced and is smaller than the original")
    func makesThumbnail() throws {
        let png = try makePNG(width: 1200, height: 900)

        let thumb = try #require(ThumbnailMaker.thumbnail(from: png))

        #expect(thumb.count < png.count)
        // Assert on PIXELS, not NSImage.size (points): points depend on DPI
        // metadata, which the JPEG re-encode does not preserve, so a
        // points-based assertion can pass or fail depending on the source
        // file's dpi tag rather than what ThumbnailMaker actually produced.
        let rep = try #require(NSBitmapImageRep(data: thumb))
        #expect(CGFloat(max(rep.pixelsWide, rep.pixelsHigh)) <= ThumbnailMaker.thumbnailLongestEdge + 1)
    }

    @Test("thumbnail preserves aspect ratio")
    func preservesAspect() throws {
        let png = try makePNG(width: 400, height: 200)

        let thumb = try #require(ThumbnailMaker.thumbnail(from: png))
        let rep = try #require(NSBitmapImageRep(data: thumb))

        #expect(abs(Double(rep.pixelsWide) / Double(rep.pixelsHigh) - 2.0) < 0.05)
    }

    @Test("a small image is not upscaled")
    func doesNotUpscale() throws {
        let png = try makePNG(width: 50, height: 50)

        // Fixture contract: a fixture that silently lies about its own
        // pixel dimensions is what let the production bug hide behind a
        // 4/5-passing suite. Pin it down before trusting it below.
        let source = try #require(NSBitmapImageRep(data: png))
        #expect(source.pixelsWide == 50 && source.pixelsHigh == 50,
                "makePNG(50,50) must really be 50x50 pixels")

        let thumb = try #require(ThumbnailMaker.thumbnail(from: png))
        let rep = try #require(NSBitmapImageRep(data: thumb))

        // Exactly 50x50, not merely "<= 50" — that way an upscale OR a
        // downscale both fail this test.
        #expect(rep.pixelsWide == 50 && rep.pixelsHigh == 50)
    }

    @Test("an image within limits is not downscaled")
    func leavesNormalImagesAlone() throws {
        let png = try makePNG(width: 800, height: 600)

        #expect(ThumbnailMaker.downscaleIfNeeded(png, uti: SupportedTypes.png) == nil,
                "nil means 'no downscale needed' — the original should be stored as-is")
    }

    @Test("garbage bytes produce nil rather than crashing")
    func garbageIsSafe() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])

        #expect(ThumbnailMaker.thumbnail(from: junk) == nil)
        #expect(ThumbnailMaker.downscaleIfNeeded(junk, uti: SupportedTypes.png) == nil)
    }

    @Test("downscaleIfNeeded never exceeds maxLongestEdge, and never exceeds the input")
    func downscaleNeverExceedsLimitOrInput() throws {
        // Wider than maxLongestEdge (8192), but modest so the test stays fast.
        let png = try makePNG(width: 9000, height: 100)

        let out = try #require(ThumbnailMaker.downscaleIfNeeded(png, uti: SupportedTypes.png))
        let rep = try #require(NSBitmapImageRep(data: out))

        #expect(CGFloat(rep.pixelsWide) <= ThumbnailMaker.maxLongestEdge,
                "downscaleIfNeeded must never produce an image larger than the limit it exists to enforce")
        #expect(rep.pixelsWide <= 9000,
                "a 'downscale' must never grow the input")
    }
}
