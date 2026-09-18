// Draws the app icon as a 1024×1024 PNG:  swift Icon/MakeIcon.swift <output.png>
import AppKit

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func withShadow(blur: CGFloat, y: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    shadow.set()
    // one shadow for the whole group, so overlapping shapes don't shade each other
    NSGraphicsContext.current!.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    draw()
    NSGraphicsContext.current!.cgContext.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// tile on the macOS icon grid: 824 pt with 100 pt margin
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
withShadow(blur: 24, y: -12, alpha: 0.35) { color(0x1B1464).setFill(); tile.fill() }
NSGradient(colors: [color(0x2EE6D6), color(0x2A7BFF), color(0x5B2BE0), color(0x2A0E73)],
           atLocations: [0, 0.4, 0.8, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -65)
// soft glow at the top
NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)])!
    .draw(fromCenter: NSPoint(x: 400, y: 900), radius: 0, toCenter: NSPoint(x: 400, y: 900), radius: 620, options: [])
NSGraphicsContext.restoreGraphicsState()

let center = NSPoint(x: 512, y: 512)

// progress ring like in the menu bar
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: 262, startAngle: 0, endAngle: 360)
track.lineWidth = 64
color(0xFFFFFF, 0.2).setStroke()
track.stroke()

withShadow(blur: 18, y: -8, alpha: 0.3) {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: 262, startAngle: 90, endAngle: -160, clockwise: true)
    arc.lineWidth = 64
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    // drive: slanted top + front, like the SF Symbol "externaldrive"
    NSColor.white.setFill()
    let top = NSBezierPath()
    top.move(to: NSPoint(x: 374, y: 500))
    top.line(to: NSPoint(x: 420, y: 600))
    top.line(to: NSPoint(x: 604, y: 600))
    top.line(to: NSPoint(x: 650, y: 500))
    top.close()
    top.lineWidth = 24
    top.lineJoinStyle = .round // rounds the corners
    top.fill()
    top.stroke()
    NSBezierPath(roundedRect: NSRect(x: 362, y: 400, width: 300, height: 132), xRadius: 34, yRadius: 34).fill()
}

// seam between top and front, slot and status light
color(0x3A4BEF).setFill()
NSBezierPath(roundedRect: NSRect(x: 390, y: 522, width: 244, height: 12), xRadius: 6, yRadius: 6).fill()
NSBezierPath(roundedRect: NSRect(x: 398, y: 450, width: 150, height: 20), xRadius: 10, yRadius: 10).fill()
color(0x2EE6D6).setFill()
NSBezierPath(ovalIn: NSRect(x: 586, y: 442, width: 36, height: 36)).fill()

NSGraphicsContext.current = nil
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
