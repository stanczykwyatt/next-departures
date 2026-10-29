// Draws the README demo (docs/demo.gif) and the link preview image (docs/social.png).
// Everything is drawn here rather than recorded, so the art never shows anyone's real desktop or
// location. The agency, its routes, stops and times, and the notes app are all made up.
//
//   swift scripts/make-art.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let ink = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.07, alpha: 1)
let ice = NSColor(srgbRed: 0.62, green: 0.82, blue: 1.0, alpha: 1)

func bitmap(_ width: Int, _ height: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Cool silver light on a dark wallpaper, like Show Desktop's art.
func wallpaper(_ rect: NSRect) {
    NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.09, blue: 0.13, alpha: 1), ending: ink)!.draw(in: rect, angle: -90)
    let glows: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
        (0.18, 0.75, 0.42, NSColor(srgbRed: 0.84, green: 0.89, blue: 0.95, alpha: 0.45)),
        (0.85, 0.72, 0.38, NSColor(srgbRed: 0.59, green: 0.68, blue: 0.81, alpha: 0.40)),
        (0.70, 0.12, 0.46, NSColor(srgbRed: 0.75, green: 0.81, blue: 0.89, alpha: 0.32)),
        (0.22, 0.15, 0.30, NSColor(srgbRed: 0.44, green: 0.53, blue: 0.65, alpha: 0.32)),
    ]
    for (x, y, r, color) in glows {
        let center = NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        NSGradient(starting: color, ending: color.withAlphaComponent(0))!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: rect.width * r, options: [])
    }
}

func symbol(_ name: String, size: CGFloat, colors: [NSColor], weight: NSFont.Weight = .regular) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: colors))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

@discardableResult
func text(
    _ string: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white,
    centered: Bool = false, mono: Bool = false
) -> CGFloat {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let width = (string as NSString).size(withAttributes: attributes).width
    (string as NSString).draw(at: NSPoint(x: centered ? point.x - width / 2 : point.x, y: point.y), withAttributes: attributes)
    return width
}

/// A dark app window with a title bar. Returns the content area.
@discardableResult
func window(_ frame: NSRect, title: String, alpha: CGFloat = 1, scale: CGFloat = 1, key: Bool) -> NSRect {
    let rect = NSRect(
        x: frame.midX - frame.width * scale / 2, y: frame.midY - frame.height * scale / 2,
        width: frame.width * scale, height: frame.height * scale
    )
    let body = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent((key ? 0.55 : 0.35) * alpha)
    shadow.shadowBlurRadius = key ? 30 : 18
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: alpha).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.12 * alpha).setStroke()
    body.lineWidth = 1
    body.stroke()
    let colors: [NSColor] = key ? [.systemRed, .systemYellow, .systemGreen] : [.gray, .gray, .gray]
    for (index, color) in colors.enumerated() {
        color.withAlphaComponent(alpha * (key ? 1 : 0.5)).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 14 + CGFloat(index) * 18, y: rect.maxY - 22, width: 11, height: 11)).fill()
    }
    text(title, at: NSPoint(x: rect.midX, y: rect.maxY - 24), size: 12, weight: .semibold, color: .white.withAlphaComponent((key ? 0.85 : 0.45) * alpha), centered: true)
    return NSRect(x: rect.minX + 18, y: rect.minY + 14, width: rect.width - 36, height: rect.height - 50)
}

func cursor(at point: NSPoint, pressed: Bool) {
    let arrow = NSBezierPath()
    let s: CGFloat = pressed ? 0.9 : 1
    arrow.move(to: point)
    arrow.line(to: NSPoint(x: point.x, y: point.y - 22 * s))
    arrow.line(to: NSPoint(x: point.x + 5.5 * s, y: point.y - 17 * s))
    arrow.line(to: NSPoint(x: point.x + 9.5 * s, y: point.y - 25.5 * s))
    arrow.line(to: NSPoint(x: point.x + 13 * s, y: point.y - 24 * s))
    arrow.line(to: NSPoint(x: point.x + 9 * s, y: point.y - 15.5 * s))
    arrow.line(to: NSPoint(x: point.x + 16 * s, y: point.y - 15.5 * s))
    arrow.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 3
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.set()
    NSColor.black.setFill()
    arrow.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setStroke()
    arrow.lineWidth = 1.5
    arrow.stroke()
}

// MARK: Scene

let width: CGFloat = 720
let height: CGFloat = 450
let menuBarHeight: CGFloat = 26
let menuWidth: CGFloat = 344
// macOS opens a menu bar menu under its icon, so the icon sits at the menu's left edge.
let iconCenter = NSPoint(x: width - 10 - menuWidth + 16, y: height - menuBarHeight / 2)
let notesFrame = NSRect(x: 30, y: 40, width: 330, height: 320)
let amber = NSColor(srgbRed: 0.93, green: 0.62, blue: 0.20, alpha: 1)
let teal = NSColor(srgbRed: 0.05, green: 0.54, blue: 0.43, alpha: 1)
let red = NSColor(srgbRed: 0.70, green: 0.14, blue: 0.23, alpha: 1)
let blue = NSColor(srgbRed: 0.16, green: 0.36, blue: 0.69, alpha: 1)

struct Ride {
    var color: NSColor
    var time: String
    var line: String
    var status: String
    var live: Bool
    var late = false
}

struct Moment {
    var cursorAt = NSPoint(x: 300, y: 200)
    var pressed = false
    var open = false
    /// The countdown next to the icon.
    var title = "4 min"
    /// The rides at the station, which update while the menu is open.
    var station: [Ride] = [
        Ride(color: teal, time: "4 min", line: "Riverside Line to Union Depot", status: "On time", live: true),
        Ride(color: teal, time: "9 min", line: "Riverside Line to Riverside", status: "1 min late", live: true),
        Ride(color: teal, time: "14 min", line: "Riverside Line to Union Depot", status: "On time", live: true),
        Ride(color: teal, time: "22 min", line: "Riverside Line to Riverside", status: "Scheduled", live: false),
    ]
    var checked = "just now"
    /// How bright the row that just changed is, fading out.
    var flash: CGFloat = 0
}

let bay: [Ride] = [
    Ride(color: red, time: "1 min", line: "3 to St. Anne Campus", status: "On time", live: true),
    Ride(color: blue, time: "7 min", line: "16 to Downtown", status: "Canceled", live: false, late: true),
    Ride(color: red, time: "9 min", line: "3 to St. Anne Campus", status: "Scheduled", live: false),
]

/// A made-up notes app, with someone's class notes open.
func notes() {
    let content = window(notesFrame, title: "Notes", key: true)
    let lines: [(String, CGFloat, NSFont.Weight, CGFloat)] = [
        ("Neuroanatomy, week 9", 17, .semibold, 0.9),
        ("Hippocampus: CA1, CA3, dentate gyrus", 12.5, .regular, 0.7),
        ("Place cells fire in one spot of a room", 12.5, .regular, 0.7),
        ("Lab at 9: bring the slides", 12.5, .regular, 0.7),
        ("", 12, .regular, 0),
        ("Questions for office hours", 14, .semibold, 0.85),
        ("Why does sleep help consolidation?", 12.5, .regular, 0.7),
    ]
    var y = content.maxY - 28
    for (string, size, weight, alpha) in lines {
        text(string, at: NSPoint(x: content.minX + 4, y: y), size: size, weight: weight, color: .white.withAlphaComponent(alpha))
        y -= size + 12
    }
}

/// The app's menu bar icon, drawn as in the app: the front of a tram.
func statusIcon(at center: NSPoint) {
    NSColor.white.set()
    let body = NSRect(x: center.x - 5.5, y: center.y - 6.5, width: 11, height: 12.5)
    let outline = NSBezierPath(roundedRect: body, xRadius: 2.6, yRadius: 2.6)
    outline.lineWidth = 1.3
    outline.stroke()
    NSBezierPath(roundedRect: NSRect(x: body.minX + 2, y: body.minY + 5.4, width: body.width - 4, height: 4.6), xRadius: 1, yRadius: 1).fill()
    for x in [body.minX + 2.3, body.maxX - 4.1] {
        NSBezierPath(ovalIn: NSRect(x: x, y: body.minY + 1.8, width: 1.8, height: 1.8)).fill()
    }
}

func panel(_ rect: NSRect) {
    let body = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor(srgbRed: 0.17, green: 0.18, blue: 0.21, alpha: 1).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.14).setStroke()
    body.lineWidth = 1
    body.stroke()
}

func separator(_ rect: NSRect, y: CGFloat) {
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSRect(x: rect.minX + 10, y: y, width: rect.width - 20, height: 1).fill()
}

func dot(_ color: NSColor, at point: NSPoint) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: point.x, y: point.y, width: 9, height: 9)).fill()
}

let menuRect = NSRect(x: width - 10 - menuWidth, y: height - menuBarHeight - 4 - 364, width: menuWidth, height: 364)

func row(_ ride: Ride, y: CGFloat, flash: CGFloat = 0) {
    let left = menuRect.minX + 14
    if flash > 0 {
        ice.withAlphaComponent(0.22 * flash).setFill()
        NSBezierPath(roundedRect: NSRect(x: menuRect.minX + 6, y: y - 5, width: menuRect.width - 12, height: 22), xRadius: 5, yRadius: 5).fill()
    }
    dot(ride.color, at: NSPoint(x: left, y: y + 2))
    let gone = ride.status == "Canceled"
    let timeColor = NSColor.white.withAlphaComponent(ride.live ? 0.95 : 0.5)
    let timeWidth = text(ride.time, at: NSPoint(x: left + 16, y: y), size: 13, weight: ride.live ? .semibold : .regular, color: timeColor)
    if gone {
        NSColor.white.withAlphaComponent(0.5).setFill()
        NSRect(x: left + 16, y: y + 7, width: timeWidth, height: 1).fill()
    }
    let lineWidth = text(ride.line, at: NSPoint(x: left + 76, y: y), size: 13, color: .white.withAlphaComponent(gone ? 0.5 : 0.92))
    let statusColor: NSColor = gone ? NSColor.systemRed : ride.status.contains("late") ? amber : .white.withAlphaComponent(0.45)
    text(ride.status, at: NSPoint(x: left + 76 + lineWidth + 8, y: y + 1), size: 10.5, color: statusColor)
}

/// The app's menu, drawn as it looks open.
func menu(_ m: Moment) {
    panel(menuRect)
    let left = menuRect.minX + 14
    var y = menuRect.maxY - 24
    text("University Station", at: NSPoint(x: left, y: y), size: 13, weight: .bold)
    y -= 24
    for (index, ride) in m.station.enumerated() {
        row(ride, y: y, flash: index == 1 ? m.flash : 0)
        y -= 22
    }
    separator(menuRect, y: y + 8)
    y -= 12
    text("University Station Bus Bay", at: NSPoint(x: left, y: y), size: 13, weight: .bold)
    y -= 24
    for ride in bay {
        row(ride, y: y)
        y -= 22
    }
    symbol("exclamationmark.triangle.fill", size: 10, colors: [amber]).draw(at: NSPoint(x: left, y: y + 1), from: .zero, operation: .sourceOver, fraction: 1)
    text("Detour: Campus Loop detoured around Library Mall", at: NSPoint(x: left + 16, y: y), size: 11, color: amber)
    y -= 14
    separator(menuRect, y: y)
    y -= 22
    text("Live from Northfield Transit, checked \(m.checked)", at: NSPoint(x: left, y: y), size: 11, color: .white.withAlphaComponent(0.45))
    y -= 24
    text("Refresh Now", at: NSPoint(x: left, y: y), size: 13)
    text("⌘R", at: NSPoint(x: menuRect.maxX - 36, y: y), size: 12, color: .white.withAlphaComponent(0.45))
    y -= 22
    text("Choose Stops…", at: NSPoint(x: left, y: y), size: 13)
    text("⌘,", at: NSPoint(x: menuRect.maxX - 34, y: y), size: 12, color: .white.withAlphaComponent(0.45))
    separator(menuRect, y: y - 9)
    y -= 30
    text("Show Next Departure in Menu Bar", at: NSPoint(x: left, y: y), size: 13)
    text("✓", at: NSPoint(x: menuRect.minX + 2, y: y), size: 12, color: .white.withAlphaComponent(0.8))
}

func scene(_ m: Moment) {
    wallpaper(NSRect(x: 0, y: 0, width: width, height: height))
    notes()

    // The menu bar.
    NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.72).setFill()
    NSRect(x: 0, y: height - menuBarHeight, width: width, height: menuBarHeight).fill()
    text("Notes", at: NSPoint(x: 18, y: height - 19), size: 12.5, weight: .bold)
    for (index, word) in ["File", "Edit", "Format", "Window"].enumerated() {
        text(word, at: NSPoint(x: 70 + CGFloat(index) * 50, y: height - 19), size: 12.5)
    }
    let titleWidth = ((m.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)])).width
    if m.pressed || m.open {
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: iconCenter.x - 14, y: height - menuBarHeight + 3, width: 32 + titleWidth, height: menuBarHeight - 6), xRadius: 5, yRadius: 5).fill()
    }
    statusIcon(at: iconCenter)
    text(m.title, at: NSPoint(x: iconCenter.x + 11, y: height - 19), size: 12.5, weight: .medium)
    for (index, name) in ["wifi", "magnifyingglass", "switch.2"].enumerated() {
        let image = symbol(name, size: 13, colors: [.white])
        image.draw(at: NSPoint(x: width - 128 + CGFloat(index) * 30, y: height - 20), from: .zero, operation: .sourceOver, fraction: 1)
    }
    text("7:56", at: NSPoint(x: width - 40, y: height - 19), size: 12.5, weight: .medium)

    if m.open { menu(m) }
    cursor(at: m.cursorAt, pressed: m.pressed)
}

func lerp(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
    let e = t * t * (3 - 2 * t)
    return NSPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
}

var frames: [(NSBitmapImageRep, Double)] = []
func frame(_ m: Moment, hold: Double = 0.07) {
    // Drawn at 2x so the GIF looks sharp on Retina screens when shown at 720 points.
    let rep = bitmap(Int(width * 2), Int(height * 2)) {
        let transform = NSAffineTransform()
        transform.scale(by: 2)
        transform.concat()
        scene(m)
    }
    frames.append((rep, hold))
}

// Taking notes, with the next train's countdown in the menu bar.
var m = Moment()
frame(m, hold: 1.6)
let onIcon = NSPoint(x: iconCenter.x + 4, y: iconCenter.y - 2)
var from = m.cursorAt
for step in 1...12 {
    m.cursorAt = lerp(from, onIcon, CGFloat(step) / 12)
    frame(m, hold: 0.04)
}
m.pressed = true
frame(m, hold: 0.12)
m.pressed = false
m.open = true
// The menu opens on both stops' next rides, live, with the detour at the bus stop.
frame(m, hold: 2.4)
// Half a minute later, while it's still open, the live feed says the westbound train is running later.
m.checked = "30 s ago"
frame(m, hold: 0.8)
m.station[0].time = "3 min"
m.station[1] = Ride(color: teal, time: "9 min", line: "Riverside Line to Riverside", status: "3 min late", live: true)
m.station[2].time = "13 min"
m.station[3].time = "21 min"
m.checked = "just now"
m.title = "3 min"
for flash in stride(from: 1.0, through: 0.0, by: -0.25) {
    m.flash = CGFloat(flash)
    frame(m, hold: flash == 1 ? 0.5 : 0.12)
}
frame(m, hold: 2.2)
// Closing the menu: the countdown stays, and nothing more is fetched until it opens again.
m.open = false
m.cursorAt = NSPoint(x: onIcon.x - 120, y: onIcon.y - 160)
frame(m, hold: 3.0)

let gifURL = URL(fileURLWithPath: "docs/demo.gif")
let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (rep, hold) in frames {
    CGImageDestinationAddImage(destination, rep.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: hold]] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write the GIF") }

// One frame on its own, for checking the art without playing the GIF.
if let preview = ProcessInfo.processInfo.environment["PREVIEW"] {
    try frames[frames.count - 3].0.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: preview))
}

// MARK: Link preview

let social = bitmap(1280, 640) {
    let rect = NSRect(x: 0, y: 0, width: 1280, height: 640)
    wallpaper(rect)
    if let icon = NSImage(contentsOfFile: "docs/icon.png") {
        icon.draw(in: NSRect(x: 640 - 80, y: 380, width: 160, height: 160))
    }
    text("Next Departures", at: NSPoint(x: 640, y: 270), size: 84, weight: .semibold, centered: true)
    text("Your stop's next bus and train, live, in the menu bar.", at: NSPoint(x: 640, y: 205), size: 30, color: .white.withAlphaComponent(0.75), centered: true)
    text("free · open source · any GTFS-realtime feed · no tracking", at: NSPoint(x: 640, y: 120), size: 22, weight: .medium, color: .white.withAlphaComponent(0.5), centered: true)
}
try social.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/social.png"))
print("Wrote docs/demo.gif and docs/social.png")
