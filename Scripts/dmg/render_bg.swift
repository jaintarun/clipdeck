import AppKit

// DMG window content area, in points.
let W: CGFloat = 640, H: CGFloat = 400

// Icons sit at Finder y=195 (top-left origin); convert to the bottom-left,
// y-up space the bitmap context draws in.
let iconY: CGFloat = H - 195
let appX: CGFloat = 170
let appsX: CGFloat = 470

func render(scale: CGFloat, to path: String) {
    // pixelsWide/High set the resolution; rep.size sets the point space. When
    // they differ the context auto-scales points -> pixels, so all drawing is
    // done in 640x400 point coordinates with NO manual scaleBy.
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!

    // Soft neutral vertical gradient (lighter at top).
    let topColor = NSColor(calibratedRed: 0.985, green: 0.985, blue: 0.995, alpha: 1)
    let bottomColor = NSColor(calibratedRed: 0.926, green: 0.928, blue: 0.945, alpha: 1)
    NSGradient(starting: bottomColor, ending: topColor)!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

    // Arrow from the app icon toward the Applications folder.
    NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.72, alpha: 1).setFill()
    let shaftLeft: CGFloat = 250, shaftRight: CGFloat = 372, half: CGFloat = 5
    NSBezierPath(roundedRect:
        NSRect(x: shaftLeft, y: iconY - half, width: shaftRight - shaftLeft, height: half * 2),
        xRadius: half, yRadius: half).fill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: shaftRight - 2, y: iconY - 15))
    head.line(to: NSPoint(x: shaftRight - 2, y: iconY + 15))
    head.line(to: NSPoint(x: shaftRight + 24, y: iconY))
    head.close()
    head.fill()

    // Instruction headline near the top.
    let title = "Drag ClipDeck onto Applications"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
        .foregroundColor: NSColor(calibratedRed: 0.42, green: 0.42, blue: 0.48, alpha: 1),
    ]
    let size = title.size(withAttributes: attrs)
    title.draw(at: NSPoint(x: (W - size.width) / 2, y: H - 70), withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()

    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let dir = CommandLine.arguments[1]
render(scale: 1, to: "\(dir)/bg.png")
render(scale: 2, to: "\(dir)/bg@2x.png")
print("rendered bg.png and bg@2x.png")
