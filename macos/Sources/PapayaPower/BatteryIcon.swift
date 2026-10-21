import AppKit

/// Draws a menu-bar battery glyph: outline, fill proportional to the charge, a bolt when
/// charging. Template image, so macOS tints it for light/dark menu bars.
enum BatteryIcon {
    static func image(percent: Double?, charging: Bool, plugged: Bool, onUPSBattery: Bool = false) -> NSImage {
        let size = NSSize(width: 26, height: 13)
        let img = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 0.75, y: 0.75, width: 22.5, height: 11.5)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.2, yRadius: 3.2)
            outline.lineWidth = 1.2
            NSColor.black.withAlphaComponent(0.55).setStroke()
            outline.stroke()
            // Terminal nub.
            let nub = NSBezierPath(roundedRect: NSRect(x: 24, y: 4.2, width: 1.8, height: 4.6), xRadius: 0.9, yRadius: 0.9)
            NSColor.black.withAlphaComponent(0.55).setFill()
            nub.fill()

            let inner = body.insetBy(dx: 2, dy: 2)
            if let p = percent {
                let w = max(1.5, inner.width * CGFloat(min(100, max(0, p)) / 100))
                let fill = NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height),
                                        xRadius: 1.6, yRadius: 1.6)
                NSColor.black.setFill()
                fill.fill()
            }
            if charging || plugged || onUPSBattery {
                // Knock the symbol out of the fill, then outline it: readable on the filled
                // part (hole) and on the empty part (outline) alike.
                let ctx = NSGraphicsContext.current!.cgContext
                let symbol = symbolPath(charging: charging, onUPSBattery: onUPSBattery, in: body)
                ctx.saveGState()
                ctx.setBlendMode(.destinationOut)
                symbol.lineWidth = 2.2
                symbol.lineJoinStyle = .round
                symbol.stroke()
                symbol.fill()
                ctx.restoreGState()
                NSColor.black.setFill()
                symbol.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Bolt when charging, plug when on adapter, exclamation mark when a UPS is on battery.
    private static func symbolPath(charging: Bool, onUPSBattery: Bool, in r: NSRect) -> NSBezierPath {
        let cx = r.midX, cy = r.midY
        if onUPSBattery {
            let p = NSBezierPath(roundedRect: NSRect(x: cx - 1.1, y: cy - 0.8, width: 2.2, height: 5.2), xRadius: 1, yRadius: 1)
            p.append(NSBezierPath(ovalIn: NSRect(x: cx - 1.2, y: cy - 4.4, width: 2.4, height: 2.4)))
            return p
        }
        if charging {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: cx + 1.4, y: cy + 5.6))
            p.line(to: NSPoint(x: cx - 3.4, y: cy - 0.6))
            p.line(to: NSPoint(x: cx - 0.2, y: cy - 0.6))
            p.line(to: NSPoint(x: cx - 1.4, y: cy - 5.6))
            p.line(to: NSPoint(x: cx + 3.4, y: cy + 0.8))
            p.line(to: NSPoint(x: cx + 0.2, y: cy + 0.8))
            p.close()
            return p
        }
        // Plug.
        let p = NSBezierPath(roundedRect: NSRect(x: cx - 3, y: cy - 1.8, width: 6, height: 4), xRadius: 1.2, yRadius: 1.2)
        p.append(NSBezierPath(rect: NSRect(x: cx - 2.2, y: cy + 2.2, width: 1.1, height: 2.6)))
        p.append(NSBezierPath(rect: NSRect(x: cx + 1.1, y: cy + 2.2, width: 1.1, height: 2.6)))
        p.append(NSBezierPath(rect: NSRect(x: cx - 0.6, y: cy - 4.8, width: 1.2, height: 3.0)))
        return p
    }
}
