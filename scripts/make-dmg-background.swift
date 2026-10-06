// Draws the DMG window background: the notch at the top, the name, and an arrow from the app to
// Applications. Usage: swift make-dmg-background.swift <out-dir>  → background.png, background@2x.png
// The layout matches scripts/dmg-settings.py (window 640×420, icons at x 170 / 470, y 236).
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let W: CGFloat = 640, H: CGFloat = 420
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ c: [CGColor], _ l: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: c as CFArray, locations: l)! }

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, centerX: CGFloat, top: CGFloat, kern: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: kern])
    let sz = a.size()
    a.draw(at: NSPoint(x: centerX - sz.width / 2, y: H - top - sz.height))
}

func draw(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Plate: a pale aqua wash, a soft teal glow behind the icons.
    ctx.drawLinearGradient(gradient([rgb(0xF7FCFB), rgb(0xE4F4F1)], [0, 1]),
                           start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    ctx.drawRadialGradient(gradient([rgb(0x7FE0C2, 0.28), rgb(0x7FE0C2, 0)], [0, 1]),
                           startCenter: CGPoint(x: W / 2, y: H - 236), startRadius: 0,
                           endCenter: CGPoint(x: W / 2, y: H - 236), endRadius: 300, options: [])

    // The notch hanging from the top edge, with two eyes glancing toward Applications.
    let nw: CGFloat = 150, nh: CGFloat = 34, ear: CGFloat = 9, r: CGFloat = 13, mid = W / 2
    let l = mid - nw / 2, rr = mid + nw / 2, b = H - nh
    let p = CGMutablePath()
    p.move(to: CGPoint(x: l - ear, y: H)); p.addLine(to: CGPoint(x: rr + ear, y: H))
    p.addQuadCurve(to: CGPoint(x: rr, y: H - ear), control: CGPoint(x: rr, y: H))
    p.addLine(to: CGPoint(x: rr, y: b + r)); p.addQuadCurve(to: CGPoint(x: rr - r, y: b), control: CGPoint(x: rr, y: b))
    p.addLine(to: CGPoint(x: l + r, y: b)); p.addQuadCurve(to: CGPoint(x: l, y: b + r), control: CGPoint(x: l, y: b))
    p.addLine(to: CGPoint(x: l, y: H - ear)); p.addQuadCurve(to: CGPoint(x: l - ear, y: H), control: CGPoint(x: l, y: H))
    p.closeSubpath()
    ctx.addPath(p); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
    for dx in [-16.0, 16.0] as [CGFloat] {
        let c = CGPoint(x: mid + dx, y: H - nh / 2 - 1)
        ctx.setFillColor(rgb(0xF2FFFB)); ctx.fillEllipse(in: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13))
        ctx.setFillColor(rgb(0x0B3D5C)); ctx.fillEllipse(in: CGRect(x: c.x + 0.5, y: c.y - 3.5, width: 7, height: 7))
    }

    text("Glancy", size: 30, weight: .bold, color: rgb(0x0B3D5C), centerX: mid, top: 62, kern: -0.4)
    text("Drag Glancy into Applications", size: 14, weight: .medium, color: rgb(0x2C6B78), centerX: mid, top: 102)

    // Arrow from the app (x 170) to Applications (x 470), a gentle arc above the icons' centre line.
    let y = H - 236, x0: CGFloat = 250, x1: CGFloat = 384
    let arc = CGMutablePath()
    arc.move(to: CGPoint(x: x0, y: y)); arc.addQuadCurve(to: CGPoint(x: x1, y: y), control: CGPoint(x: (x0 + x1) / 2, y: y + 30))
    ctx.saveGState()
    ctx.addPath(arc); ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x1F8A9E), rgb(0x3FBFA6)], [0, 1]),
                           start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y), options: [])
    ctx.restoreGState()
    // Head, along the arc's end tangent (control → end).
    let ang = atan2(y - (y + 30), x1 - (x0 + x1) / 2), len: CGFloat = 16, spread: CGFloat = 0.5
    let tip = CGPoint(x: x1 + 4 * cos(ang), y: y + 4 * sin(ang))
    let head = CGMutablePath()
    head.move(to: CGPoint(x: tip.x - len * cos(ang - spread), y: tip.y - len * sin(ang - spread)))
    head.addLine(to: tip)
    head.addLine(to: CGPoint(x: tip.x - len * cos(ang + spread), y: tip.y - len * sin(ang + spread)))
    ctx.addPath(head); ctx.setStrokeColor(rgb(0x3FBFA6)); ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()

    text("Signed and notarized  ·  github.com/giacolaiacomo/glancy", size: 11, weight: .regular,
         color: rgb(0x6F9AA3), centerX: mid, top: 386)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! draw(scale: 1).write(to: out.appendingPathComponent("background.png"))
try! draw(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
