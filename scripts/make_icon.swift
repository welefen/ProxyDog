import AppKit
import Foundation

setbuf(stdout, nil)

/// Renders the ProxyDog app icon: a graphite squircle with two opposed traffic
/// arrows (blue out, white in) - the "inspect what goes both ways" mark.
/// Usage: swift make_icon.swift <output-iconset-dir>

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let scale = size / 1024.0
    func s(_ value: CGFloat) -> CGFloat { value * scale }

    let bodyRect = NSRect(x: s(92), y: s(92), width: s(840), height: s(840))
    let radius = s(188)

    let squircle = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)
    let bodyGradient = NSGradient(colors: [color(0x3B424B), color(0x161920)])!
    bodyGradient.draw(in: squircle, angle: -90)

    // Hairline highlight along the top edge gives the tile a little material.
    let inset = bodyRect.insetBy(dx: s(2), dy: s(2))
    let edge = NSBezierPath(roundedRect: inset, xRadius: radius - s(2), yRadius: radius - s(2))
    edge.lineWidth = s(3)
    color(0xF2F5FA, alpha: 0.15).setStroke()
    edge.stroke()

    // Two horizontal traffic arrows, the upper one tinted with the product accent.
    func arrow(centerY: CGFloat, pointingRight: Bool, tint: NSColor) {
        let left = bodyRect.minX + s(232)
        let right = bodyRect.maxX - s(232)
        let head = s(122)
        let path = NSBezierPath()
        if pointingRight {
            path.move(to: NSPoint(x: left, y: centerY))
            path.line(to: NSPoint(x: right, y: centerY))
            path.move(to: NSPoint(x: right - head, y: centerY + head * 0.62))
            path.line(to: NSPoint(x: right, y: centerY))
            path.line(to: NSPoint(x: right - head, y: centerY - head * 0.62))
        } else {
            path.move(to: NSPoint(x: right, y: centerY))
            path.line(to: NSPoint(x: left, y: centerY))
            path.move(to: NSPoint(x: left + head, y: centerY + head * 0.62))
            path.line(to: NSPoint(x: left, y: centerY))
            path.line(to: NSPoint(x: left + head, y: centerY - head * 0.62))
        }
        path.lineWidth = s(74)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        tint.setStroke()
        path.stroke()
    }

    arrow(centerY: bodyRect.midY + s(112), pointingRight: true, tint: color(0x5B9BFF))
    arrow(centerY: bodyRect.midY - s(112), pointingRight: false, tint: color(0xF2F5FA))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    let rep = drawIcon(size: variant.size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: outputDirectory.appendingPathComponent(variant.name))
}

print("Wrote iconset to \(outputDirectory.path)")
