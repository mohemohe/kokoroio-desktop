#!/usr/bin/env swift
// Original artwork. Run from the repository root, then:
// iconutil -c icns Resources/KokoroDesktop.iconset -o Resources/KokoroDesktop.icns
import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/KokoroDesktop.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func makeIcon(pixels: Int, filename: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()

    let base = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 204, yRadius: 204)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.63, blue: 0.47, alpha: 1), ending: NSColor(srgbRed: 0.06, green: 0.27, blue: 0.25, alpha: 1))!
    gradient.draw(in: base, angle: -90)

    // A speech bubble around a heart, drawn on a consistent 1024-point canvas.
    let bubble = NSBezierPath()
    bubble.move(to: NSPoint(x: 332, y: 271))
    bubble.line(to: NSPoint(x: 261, y: 182))
    bubble.line(to: NSPoint(x: 273, y: 336))
    bubble.curve(to: NSPoint(x: 202, y: 521), controlPoint1: NSPoint(x: 226, y: 384), controlPoint2: NSPoint(x: 202, y: 449))
    bubble.curve(to: NSPoint(x: 512, y: 797), controlPoint1: NSPoint(x: 202, y: 682), controlPoint2: NSPoint(x: 341, y: 797))
    bubble.curve(to: NSPoint(x: 822, y: 521), controlPoint1: NSPoint(x: 683, y: 797), controlPoint2: NSPoint(x: 822, y: 682))
    bubble.curve(to: NSPoint(x: 512, y: 245), controlPoint1: NSPoint(x: 822, y: 360), controlPoint2: NSPoint(x: 683, y: 245))
    bubble.curve(to: NSPoint(x: 332, y: 271), controlPoint1: NSPoint(x: 448, y: 245), controlPoint2: NSPoint(x: 386, y: 252))
    bubble.close()
    NSColor(srgbRed: 0.97, green: 0.99, blue: 0.97, alpha: 1).setFill()
    bubble.fill()

    let heart = NSBezierPath()
    heart.move(to: NSPoint(x: 512, y: 365))
    heart.curve(to: NSPoint(x: 343, y: 560), controlPoint1: NSPoint(x: 446, y: 426), controlPoint2: NSPoint(x: 343, y: 485))
    heart.curve(to: NSPoint(x: 512, y: 608), controlPoint1: NSPoint(x: 343, y: 669), controlPoint2: NSPoint(x: 460, y: 694))
    heart.curve(to: NSPoint(x: 681, y: 560), controlPoint1: NSPoint(x: 564, y: 694), controlPoint2: NSPoint(x: 681, y: 669))
    heart.curve(to: NSPoint(x: 512, y: 365), controlPoint1: NSPoint(x: 681, y: 485), controlPoint2: NSPoint(x: 578, y: 426))
    heart.close()
    NSColor(srgbRed: 0.10, green: 0.48, blue: 0.37, alpha: 1).setFill()
    heart.fill()

    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
}

for size in [16, 32, 128, 256, 512] {
    try makeIcon(pixels: size, filename: "icon_\(size)x\(size).png")
    try makeIcon(pixels: size * 2, filename: "icon_\(size)x\(size)@2x.png")
}
