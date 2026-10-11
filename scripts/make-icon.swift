// Draws the Rushes app icon: a memory card with a play button on a glassy plate.
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
// A warm glow from the lower corner, the second hue of the family.
NSGradient(colors: [color(0xFFB0CB, 0.55), color(0xFFB0CB, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(fromCenter: NSPoint(x: 820, y: 170), radius: 0, toCenter: NSPoint(x: 820, y: 170), radius: 520, options: [])
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
context.restoreGState()

// The card: a rectangle with the corner cut at the top right, like every SD card.
func cardPath(in rect: NSRect, cut: CGFloat, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX + radius, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
    path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + radius), controlPoint1: NSPoint(x: rect.maxX, y: rect.minY), controlPoint2: NSPoint(x: rect.maxX, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - cut))
    path.line(to: NSPoint(x: rect.maxX - cut, y: rect.maxY))
    path.line(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
    path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - radius), controlPoint1: NSPoint(x: rect.minX, y: rect.maxY), controlPoint2: NSPoint(x: rect.minX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
    path.curve(to: NSPoint(x: rect.minX + radius, y: rect.minY), controlPoint1: NSPoint(x: rect.minX, y: rect.minY), controlPoint2: NSPoint(x: rect.minX, y: rect.minY))
    path.close()
    return path
}

let card = NSRect(x: 322, y: 232, width: 380, height: 520)
let cardShape = cardPath(in: card, cut: 120, radius: 46)

context.saveGState()
let lift = NSShadow()
lift.shadowColor = NSColor.black.withAlphaComponent(0.38)
lift.shadowOffset = NSSize(width: 0, height: -18)
lift.shadowBlurRadius = 34
lift.set()
color(0xFFFFFF).setFill()
cardShape.fill()
context.restoreGState()

context.saveGState()
cardShape.addClip()
NSGradient(colors: [color(0xFFFFFF), color(0xDAD9FB)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: card, angle: -70)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.8), NSColor.white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: card.minX, y: card.midY + 40, width: card.width, height: card.height / 2), angle: -90)
// The contacts along the bottom.
for index in 0 ..< 6 {
    let pad = NSRect(x: card.minX + 52 + CGFloat(index) * 50, y: card.minY + 26, width: 30, height: 74)
    color(0x934464, 0.85).setFill()
    NSBezierPath(roundedRect: pad, xRadius: 8, yRadius: 8).fill()
}
context.restoreGState()
color(0xFFFFFF, 0.9).setStroke()
cardShape.lineWidth = 3
cardShape.stroke()

// A play button: what the card is about.
let play = NSBezierPath()
play.move(to: NSPoint(x: 452, y: 450))
play.line(to: NSPoint(x: 452, y: 640))
play.line(to: NSPoint(x: 616, y: 545))
play.close()
context.saveGState()
play.addClip()
NSGradient(colors: [color(0x7A79EE), color(0x2E2C6B)], atLocations: [0, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: 440, y: 440, width: 190, height: 210), angle: -60)
context.restoreGState()
NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: arguments[1]))
