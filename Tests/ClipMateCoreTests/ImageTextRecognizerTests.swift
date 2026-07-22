import AppKit
import Foundation
import Testing
@testable import ClipMateCore

/// Renders a known string into a bitmap so recognition is deterministic —
/// Vision reads clean 28pt rendered text reliably. Shared with the
/// CaptureEngine OCR test (same module, so keep it internal, not private).
func renderTextImagePNG(_ string: String) -> Data {
    let size = NSSize(width: 480, height: 80)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (string as NSString).draw(at: NSPoint(x: 20, y: 24), withAttributes: [
        .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
        .foregroundColor: NSColor.black,
    ])
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
}

@Suite("ImageTextRecognizer")
struct ImageTextRecognizerTests {

    @Test("recognizes rendered text in a PNG")
    func recognizesRenderedText() {
        let png = renderTextImagePNG("CLIPMATE OCR 42")
        let text = ImageTextRecognizer.recognizeText(in: png)
        #expect(text?.contains("CLIPMATE") == true)
        #expect(text?.contains("42") == true)
    }

    @Test("undecodable data returns nil, never throws")
    func garbageReturnsNil() {
        #expect(ImageTextRecognizer.recognizeText(in: Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test("a blank image returns nil, not an empty string")
    func blankImageReturnsNil() {
        let png = renderTextImagePNG("")
        #expect(ImageTextRecognizer.recognizeText(in: png) == nil)
    }
}
