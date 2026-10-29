// Draws the app icon and writes it to Resources/AppIcon.icns, plus docs/icon.png for the website.
//
//   swift scripts/make-icon.swift
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

/// Draws the icon on a 1024-point canvas, scaled to `pixels`.
func icon(pixels: Int) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()

    let slate = NSColor(srgbRed: 0.13, green: 0.17, blue: 0.27, alpha: 1)
    let ice = NSColor(srgbRed: 0.62, green: 0.82, blue: 1.0, alpha: 1)

    // The rounded tile, with the soft shadow macOS icons sit on. Same tile and light as Show Desktop.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = .black.withAlphaComponent(0.3)
    tileShadow.shadowBlurRadius = 24
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.set()
    slate.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(srgbRed: 0.80, green: 0.87, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.57, blue: 0.75, alpha: 1),
        slate,
    ])!.draw(in: tile, angle: -90)

    /// A rounded bar, with a soft shadow, or glowing in `color` when it's the newest part.
    func bar(_ rect: NSRect, color: NSColor, glow: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        if glow {
            shadow.shadowColor = color.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = 34
        } else {
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -6)
        }
        shadow.set()
        color.setFill()
        let radius = min(rect.width, rect.height) / 2
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The tram's body: white, with rounded corners and a soft shadow.
    func sheet(_ rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.white.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 96, yRadius: 96).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // The front of a tram coming toward you: a white body with a slate windshield, a destination
    // sign glowing ice blue above it, two ice headlights, and the rails running out below.
    let body = NSRect(x: 292, y: 250, width: 440, height: 560)
    sheet(body)
    NSGraphicsContext.saveGraphicsState()
    slate.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: NSRect(x: 336, y: 452, width: 352, height: 214), xRadius: 30, yRadius: 30).fill()
    NSGraphicsContext.restoreGraphicsState()
    // A soft reflection across the windshield.
    let shine = NSBezierPath()
    shine.move(to: NSPoint(x: 380, y: 452))
    shine.line(to: NSPoint(x: 470, y: 666))
    shine.line(to: NSPoint(x: 540, y: 666))
    shine.line(to: NSPoint(x: 450, y: 452))
    shine.close()
    NSColor.white.withAlphaComponent(0.08).setFill()
    shine.fill()
    bar(NSRect(x: 352, y: 704, width: 320, height: 62), color: ice, glow: true)
    for x in [350.0, 618.0] {
        bar(NSRect(x: x, y: 318, width: 56, height: 56), color: ice, glow: true)
    }
    bar(NSRect(x: 452, y: 330, width: 120, height: 30), color: slate.withAlphaComponent(0.35), glow: false)
    // The pantograph on the roof.
    let pole = NSBezierPath()
    pole.move(to: NSPoint(x: 430, y: 810))
    pole.line(to: NSPoint(x: 512, y: 872))
    pole.line(to: NSPoint(x: 594, y: 810))
    pole.lineWidth = 22
    pole.lineCapStyle = .round
    pole.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.9).setStroke()
    pole.stroke()
    // The rails, narrowing toward you like a track seen from the platform.
    for (top, bottom) in [(360.0, 300.0), (664.0, 724.0)] {
        let rail = NSBezierPath()
        rail.move(to: NSPoint(x: top, y: 246))
        rail.line(to: NSPoint(x: bottom, y: 140))
        rail.lineWidth = 20
        rail.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.55).setStroke()
        rail.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return image
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = icon(pixels: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try icon(pixels: 256).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
Swift.print("Wrote \(output) and docs/icon.png")
