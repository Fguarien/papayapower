// Draws the PapayaPower icon (half a papaya with a lightning bolt) into an .iconset folder.
// No binary asset is committed: the icon is rebuilt from this file.
//   swift Tools/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded-square tile (macOS icon grid: 824 pt body, 100 pt margin).
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s,
                  color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSGradient(colors: [NSColor(red: 0.99, green: 0.96, blue: 0.86, alpha: 1),
                        NSColor(red: 0.98, green: 0.88, blue: 0.70, alpha: 1)])!
        .draw(in: tilePath, angle: -90)
    ctx.restoreGState()

    // Papaya half: green skin, orange flesh, an oval of dark seeds.
    let cx = 512 * s, cy = 500 * s
    let skin = NSBezierPath(ovalIn: NSRect(x: cx - 250 * s, y: cy - 330 * s, width: 500 * s, height: 660 * s))
    NSColor(red: 0.35, green: 0.62, blue: 0.24, alpha: 1).setFill()
    skin.fill()
    let flesh = NSBezierPath(ovalIn: NSRect(x: cx - 222 * s, y: cy - 300 * s, width: 444 * s, height: 600 * s))
    NSGradient(colors: [NSColor(red: 1.00, green: 0.62, blue: 0.22, alpha: 1),
                        NSColor(red: 0.96, green: 0.42, blue: 0.13, alpha: 1)])!
        .draw(in: flesh, relativeCenterPosition: NSPoint(x: 0, y: 0.2))
    let cavity = NSBezierPath(ovalIn: NSRect(x: cx - 105 * s, y: cy - 190 * s, width: 210 * s, height: 380 * s))
    NSColor(red: 0.85, green: 0.33, blue: 0.10, alpha: 1).setFill()
    cavity.fill()
    NSColor(red: 0.13, green: 0.10, blue: 0.08, alpha: 1).setFill()
    let seeds: [(CGFloat, CGFloat)] = [(-50, 120), (40, 140), (-70, 50), (60, 60), (-10, 80),
                                      (-75, -30), (70, -20), (0, 10), (-55, -110), (50, -100),
                                      (-5, -60), (-20, -150), (30, -160)]
    for (dx, dy) in seeds {
        NSBezierPath(ovalIn: NSRect(x: cx + dx * s - 22 * s, y: cy + dy * s - 22 * s,
                                    width: 44 * s, height: 44 * s)).fill()
    }

    // Lightning bolt across the fruit.
    let bolt = NSBezierPath()
    let pts: [(CGFloat, CGFloat)] = [(560, 860), (380, 470), (500, 470), (430, 150), (660, 560), (530, 560), (640, 860)]
    bolt.move(to: NSPoint(x: pts[0].0 * s, y: pts[0].1 * s))
    for p in pts.dropFirst() { bolt.line(to: NSPoint(x: p.0 * s, y: p.1 * s)) }
    bolt.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(red: 1.0, green: 0.86, blue: 0.20, alpha: 1).setFill()
    bolt.fill()
    ctx.restoreGState()
    NSColor(red: 0.55, green: 0.33, blue: 0.0, alpha: 1).setStroke()
    bolt.lineWidth = 10 * s
    bolt.lineJoinStyle = .round
    bolt.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = draw(size: px).representation(using: .png, properties: [:])!
        try! data.write(to: out.appendingPathComponent(name))
    }
}
// A 1024 px preview for README / Linux.
try! draw(size: 1024).representation(using: .png, properties: [:])!
    .write(to: out.deletingLastPathComponent().appendingPathComponent("papayapower-1024.png"))
