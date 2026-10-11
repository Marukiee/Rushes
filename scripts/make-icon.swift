// Draws the Rushes app icon: a memory card and a play button, overlapping like the two pills of Tandem.
// Usage: swift scripts/make-icon.swift <output.png> [size]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png> [size]\n".utf8))
    exit(1)
}
let size = arguments.count > 2 ? CGFloat(Double(arguments[2]) ?? 1024) : 1024

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.scaleBy(x: size / 1024, y: size / 1024)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// The plate: macOS icons sit on a rounded square with room around it for the shadow.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 186, yRadius: 186)

context.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
color(0x2E2C6B).setFill()
platePath.fill()
context.restoreGState()

context.saveGState()
platePath.addClip()
NSGradient(colors: [color(0x7A79EE), color(0x4A49C4), color(0x2E2C6B)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: plate, angle: -60)
// A soft light from the top, so the plate reads as glass.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
context.restoreGState()

// Two shapes that overlap, like the two pills of Tandem: a memory card behind, a play button in front.
func lift(_ path: NSBezierPath, fill: [NSColor], angle: CGFloat) {
    context.saveGState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    glow.shadowOffset = NSSize(width: 0, height: -10)
    glow.shadowBlurRadius = 22
    glow.set()
    fill[0].setFill()
    path.fill()
    context.setShadow(offset: .zero, blur: 0)
    path.addClip()
    let bounds = path.bounds
    NSGradient(colors: fill)!.draw(in: bounds, angle: angle)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2), angle: -90)
    context.restoreGState()
}

/// A polygon with every corner rounded by the same radius.
func rounded(_ points: [NSPoint], radius: CGFloat) -> NSBezierPath {
    let path = CGMutablePath()
    let count = points.count
    for index in 0 ..< count {
        let previous = points[(index + count - 1) % count], current = points[index], next = points[(index + 1) % count]
        let start = NSPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
        if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
        path.addArc(tangent1End: current, tangent2End: next, radius: radius)
    }
    path.closeSubpath()
    return NSBezierPath(cgPath: path)
}

/// Puts a shape with its middle at a point, turned by an angle around that middle.
func place(_ path: NSBezierPath, at center: NSPoint, degrees: CGFloat) {
    let bounds = path.bounds
    var move = AffineTransform(translationByX: center.x, byY: center.y)
    move.rotate(byDegrees: degrees)
    move.translate(x: -bounds.midX, y: -bounds.midY)
    path.transform(using: move)
}

// The card, tilted a little against the play button: the cut corner at the top right is what makes it a memory card.
let cardShape = rounded([NSPoint(x: 0, y: 0), NSPoint(x: 340, y: 0), NSPoint(x: 340, y: 340), NSPoint(x: 220, y: 470), NSPoint(x: 0, y: 470)], radius: 60)
place(cardShape, at: NSPoint(x: 598, y: 508), degrees: -7)
lift(cardShape, fill: [color(0xFFB0CB), color(0xE8779F)], angle: 90)

let playShape = rounded([NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 420), NSPoint(x: 364, y: 210)], radius: 62)
place(playShape, at: NSPoint(x: 408, y: 508), degrees: 0)
lift(playShape, fill: [color(0xFFFFFF), color(0xC9C8FA)], angle: 90)

NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: arguments[1]))
