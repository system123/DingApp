import AppKit

// The Ding bell: caught mid-swing, clapper lagging behind, motion marks trailing on the right.
// Geometry lives in a 20 x 18 pt box and is shared by the menu bar mark and the app icon.
struct Bell {
    let arcs: [NSBezierPath] // motion marks, inner first (stroke them)
    let body, lip, knob, clapper: NSBezierPath

    init() {
        // Drawn upright around x = 10, then swung 16° about the knob (bottom swings left).
        let t = NSAffineTransform()
        t.translateX(by: 10, yBy: 16.5); t.rotate(byDegrees: -16); t.translateX(by: -10, yBy: -16.5)
        func p(_ x: Double, _ y: Double) -> NSPoint { t.transform(NSPoint(x: x, y: y)) }
        func dot(_ c: NSPoint, _ r: Double) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

        arcs = [7.4, 9.9].map { r in
            let arc = NSBezierPath()
            arc.appendArc(withCenter: p(10, 9.2), radius: r, startAngle: -42, endAngle: 2)
            arc.lineCapStyle = .round
            return arc
        }
        body = NSBezierPath()
        body.move(to: p(5.2, 5.4))
        body.curve(to: p(6.7, 11.3), controlPoint1: p(6.1, 6.4), controlPoint2: p(6.7, 8.8))
        body.curve(to: p(13.3, 11.3), controlPoint1: p(6.7, 15.6), controlPoint2: p(13.3, 15.6))
        body.curve(to: p(14.8, 5.4), controlPoint1: p(13.3, 8.8), controlPoint2: p(13.9, 6.4))
        body.close()
        body.lineJoinStyle = .round
        lip = NSBezierPath(roundedRect: NSRect(x: 4.4, y: 4.4, width: 11.2, height: 1.6), xRadius: 0.8, yRadius: 0.8)
        lip.transform(using: t as AffineTransform)
        knob = dot(p(10, 15.8), 0.9)
        clapper = dot(p(11.0, 2.6), 1.35)
    }

    func scaled(_ k: Double, dx: Double, dy: Double) -> Bell {
        var a = AffineTransform(translationByX: dx, byY: dy); a.scale(k)
        func m(_ b: NSBezierPath) -> NSBezierPath { let c = b.copy() as! NSBezierPath; c.transform(using: a); return c }
        return Bell(arcs: arcs.map(m), body: m(body), lip: m(lip), knob: m(knob), clapper: m(clapper))
    }

    private init(arcs: [NSBezierPath], body: NSBezierPath, lip: NSBezierPath, knob: NSBezierPath, clapper: NSBezierPath) {
        self.arcs = arcs; self.body = body; self.lip = lip; self.knob = knob; self.clapper = clapper
    }
}

// Menu bar mark: outline when idle, solid when alarms are pending; a tiny steaming mug joins it
// while keep-awake is on. Template image, so macOS tints it for light/dark menu bars.
func dingMark(filled: Bool, mug: Bool) -> NSImage {
    let h = 18.0, bellW = 20.0, mugW = mug ? 9.0 : 0
    let img = NSImage(size: NSSize(width: bellW + mugW, height: h), flipped: false) { _ in
        let bell = Bell(), line = 1.4
        for (arc, a) in zip(bell.arcs, [1.0, 0.5]) {
            NSColor.black.withAlphaComponent(a).set(); arc.lineWidth = line; arc.stroke()
        }
        NSColor.black.set()
        bell.body.lineWidth = line
        filled ? bell.body.fill() : bell.body.stroke()
        [bell.lip, bell.knob, bell.clapper].forEach { $0.fill() }

        if mug {
            let x = bellW + 0.5
            NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: 5.6, height: 6.4), xRadius: 1.2, yRadius: 1.2).fill()
            let handle = NSBezierPath()
            handle.appendArc(withCenter: NSPoint(x: x + 5.6, y: 5.2), radius: 1.7, startAngle: -70, endAngle: 70)
            handle.lineWidth = 1.2; handle.stroke()
            for dx in [1.6, 4.0] { // steam
                let s = NSBezierPath()
                s.move(to: NSPoint(x: x + dx, y: 9.8))
                s.curve(to: NSPoint(x: x + dx, y: 14.2), controlPoint1: NSPoint(x: x + dx + 1.3, y: 11.2),
                        controlPoint2: NSPoint(x: x + dx - 1.3, y: 12.8))
                s.lineWidth = 1.1; s.lineCapStyle = .round; s.stroke()
            }
        }
        return true
    }
    img.isTemplate = true
    return img
}

// App icon: golden bell on an indigo squircle, following Apple's macOS icon grid (824/1024 body).
func drawAppIcon(_ s: Double) {
    func rgb(_ hex: Int, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255, alpha: a)
    }
    let inset = s * 100 / 1024, side = s - 2 * inset
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
                            xRadius: side * 0.225, yRadius: side * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = .black.withAlphaComponent(0.3); drop.shadowOffset = NSSize(width: 0, height: -s * 0.012); drop.shadowBlurRadius = s * 0.03
    drop.set()
    rgb(0x3A22B8).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: rgb(0x7B6CFF), ending: rgb(0x3A1FB0))!.draw(in: tile, angle: -90)
    NSGradient(colors: [.white.withAlphaComponent(0.18), .white.withAlphaComponent(0)])!.draw(in: tile, angle: -90) // top sheen

    let k = side * 0.7 / 20
    let bell = Bell().scaled(k, dx: s / 2 - 10 * k, dy: s / 2 - 9.4 * k)
    for (arc, a) in zip(bell.arcs, [0.95, 0.5]) {
        rgb(0xFFE29A, a).setStroke(); arc.lineWidth = 1.5 * k; arc.stroke()
    }
    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = rgb(0x1A0B60, 0.45); lift.shadowOffset = NSSize(width: 0, height: -s * 0.014); lift.shadowBlurRadius = s * 0.025
    lift.set()
    let gold = NSGradient(starting: rgb(0xFFE07A), ending: rgb(0xFFA62B))!
    gold.draw(in: bell.body, angle: -90)
    rgb(0xFFB940).setFill(); bell.lip.fill(); bell.knob.fill()
    rgb(0xF08A00).setFill(); bell.clapper.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func appIconPNG(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawAppIcon(Double(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Used by build.sh: writes the .iconset that iconutil turns into AppIcon.icns.
func writeIconset(_ dir: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for pt in [16, 32, 128, 256, 512] {
        try appIconPNG(pt).write(to: URL(fileURLWithPath: "\(dir)/icon_\(pt)x\(pt).png"))
        try appIconPNG(pt * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(pt)x\(pt)@2x.png"))
    }
}
