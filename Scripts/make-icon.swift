#!/usr/bin/env swift
// Generates Resources/AppIcon.icns source PNGs. Standalone script (not part of
// the SPM package) — run with `swift Scripts/make-icon.swift`, then feed the
// resulting build/AppIcon.iconset to `iconutil`.
//
// Draws into an explicitly-sized NSBitmapImageRep bound to its own
// NSGraphicsContext — never lockFocus(), whose output scales with whatever
// display happens to be attached, producing wrong pixel dimensions.
import AppKit

func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let s = CGFloat(size)

    // Background squircle: vertical gradient, top -> bottom.
    let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                               xRadius: s * 0.2237, yRadius: s * 0.2237)
    NSGradient(colors: [color(0x5A, 0xA5, 0xF7), color(0x2D, 0x6B, 0xD8)])!
        .draw(in: bgPath, angle: -90)

    // Clipboard board: white rounded rect, subtle shadow.
    let boardW = s * 0.58
    let boardH = s * 0.68
    let boardRect = NSRect(x: (s - boardW) / 2, y: (s - boardH) / 2, width: boardW, height: boardH)
    let boardRadius = s * 0.08
    let boardPath = NSBezierPath(roundedRect: boardRect, xRadius: boardRadius, yRadius: boardRadius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.02
    shadow.set()
    NSColor.white.setFill()
    boardPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Paper inset: very light gray, keeps the white board visible as a border.
    let paperRect = boardRect.insetBy(dx: s * 0.035, dy: s * 0.035)
    let paperPath = NSBezierPath(roundedRect: paperRect, xRadius: boardRadius * 0.7, yRadius: boardRadius * 0.7)
    color(0xF0, 0xF2, 0xF5).setFill()
    paperPath.fill()

    // Metal clip tab, straddling the board's top edge. Gray gradient, top -> bottom.
    let clipW = s * 0.24
    let clipH = s * 0.09
    let clipRect = NSRect(x: (s - clipW) / 2, y: boardRect.maxY - clipH / 2, width: clipW, height: clipH)
    let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: clipH * 0.4, yRadius: clipH * 0.4)
    NSGradient(colors: [color(0xC8, 0xCD, 0xD4), color(0x9A, 0xA1, 0xAB)])!
        .draw(in: clipPath, angle: -90)

    // Three text-suggesting lines across the lower half of the paper.
    color(0xB9, 0xC2, 0xCE).setStroke()
    let lineWidth = s * 0.04
    let lineX0 = paperRect.minX + paperRect.width * 0.15
    let lineX1 = paperRect.maxX - paperRect.width * 0.15
    for fraction: CGFloat in [0.28, 0.42, 0.56] {
        let y = paperRect.minY + paperRect.height * fraction
        let line = NSBezierPath()
        line.lineWidth = lineWidth
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: lineX0, y: y))
        line.line(to: NSPoint(x: lineX1, y: y))
        line.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG for \(url.path)")
    }
    do {
        try data.write(to: url)
        print("wrote \(url.path)")
    } catch {
        fatalError("Failed to write \(url.path): \(error)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = root.appendingPathComponent("build/AppIcon.iconset")

try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for n in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(size: n), to: iconsetDir.appendingPathComponent("icon_\(n)x\(n).png"))
    writePNG(drawIcon(size: n * 2), to: iconsetDir.appendingPathComponent("icon_\(n)x\(n)@2x.png"))
}
