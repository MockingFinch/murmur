// Draws Murmur's app icon and writes an .iconset folder.
// usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// The 1024 design, scaled to `px`.
func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS grid: an 824 squircle centred on 1024, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.32)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x1B1D36).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x2E3152), color(0x121327)])!.draw(in: tile, angle: -90)
    // Warm light from the top right, cool from the bottom left.
    NSGradient(colors: [color(0xFF3B7A, 0.42), color(0xFF3B7A, 0)])!
        .draw(fromCenter: NSPoint(x: 820, y: 860), radius: 0, toCenter: NSPoint(x: 820, y: 860), radius: 560, options: [])
    NSGradient(colors: [color(0x8B6CFF, 0.34), color(0x8B6CFF, 0)])!
        .draw(fromCenter: NSPoint(x: 160, y: 120), radius: 0, toCenter: NSPoint(x: 160, y: 120), radius: 620, options: [])
    // A glassy top edge.
    NSGradient(colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)])!
        .draw(in: CGRect(x: 100, y: 600, width: 824, height: 324), angle: -90)

    // The mark: a voice (warm, uneven) settling into a line of text (white, even).
    let heights: [CGFloat] = [0.30, 0.62, 1.0, 0.74, 0.46, 0.22, 0.22, 0.22]
    let barWidth: CGFloat = 52
    let gap: CGFloat = 30
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let x0 = 512 - total / 2
    let maxH: CGFloat = 420
    for (i, h) in heights.enumerated() {
        let height = max(barWidth, h * maxH)
        let bar = CGRect(x: x0 + CGFloat(i) * (barWidth + gap), y: 512 - height / 2, width: barWidth, height: height)
        let path = NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2)
        if i < 5 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSGradient(colors: [color(0xFF9A5B), color(0xFF3B7A)])!.draw(in: bar, angle: -90)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            color(0xFFFFFF, 0.92).setFill()
            path.fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    color(0xFFFFFF, 0.10).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
    rim.lineWidth = 3
    rim.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let data = draw(points * scale).representation(using: .png, properties: [:])!
        try data.write(to: out.appendingPathComponent(name))
    }
}
