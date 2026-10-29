import AppKit

/// The menu bar icon: the front of a tram, with its windshield, headlights and a stop sign's post
/// beside it.
enum StatusIcon {
    static func image(alert: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.set()
            let shift: CGFloat = alert ? -1.5 : 0
            let body = NSRect(x: 3.5 + shift, y: 3, width: 11, height: 12.5)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.6, yRadius: 2.6)
            outline.lineWidth = 1.3
            outline.stroke()
            // The windshield, then the headlights below it.
            NSBezierPath(roundedRect: NSRect(x: body.minX + 2, y: body.minY + 5.4, width: body.width - 4, height: 4.6), xRadius: 1, yRadius: 1).fill()
            for x in [body.minX + 2.3, body.maxX - 4.1] {
                NSBezierPath(ovalIn: NSRect(x: x, y: body.minY + 1.8, width: 1.8, height: 1.8)).fill()
            }
            // The pantograph on the roof, and the wheels.
            let wire = NSBezierPath()
            wire.move(to: NSPoint(x: body.midX - 2.2, y: body.maxY))
            wire.line(to: NSPoint(x: body.midX, y: body.maxY + 2))
            wire.line(to: NSPoint(x: body.midX + 2.2, y: body.maxY))
            wire.lineWidth = 1.1
            wire.stroke()
            for x in [body.minX + 1.6, body.maxX - 3.4] {
                NSBezierPath(roundedRect: NSRect(x: x, y: body.minY - 1.8, width: 1.8, height: 1.8), xRadius: 0.4, yRadius: 0.4).fill()
            }
            if alert {
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = alert ? "Next Departures, with a service alert" : "Next Departures"
        return image
    }

    /// A small dot in a route's color, as on the agency's maps.
    static func routeDot(_ hex: String?, size: CGFloat = 10) -> NSImage {
        let color = hex.flatMap(color) ?? .secondaryLabelColor
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 0.5
            ring.stroke()
            return true
        }
        return image
    }

    static func color(_ hex: String) -> NSColor? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
