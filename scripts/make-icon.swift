// Draws the Glancy app icon: the notch, as a black mask hanging from the top edge, with two eyes
// glancing to the side, on a deep-teal-to-aqua plate. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ c: [CGColor], _ l: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: space, colors: c as CFArray, locations: l)! }

/// The notch: flat top, concave ears at the top corners, rounded bottom corners (y-up).
func notchPath(top: CGFloat, midX: CGFloat, width w: CGFloat, height h: CGFloat, ear: CGFloat, bottomR: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let l = midX - w / 2, r = midX + w / 2, b = top - h
    p.move(to: CGPoint(x: l - ear, y: top))
    p.addLine(to: CGPoint(x: r + ear, y: top))
    p.addQuadCurve(to: CGPoint(x: r, y: top - ear), control: CGPoint(x: r, y: top))
    p.addLine(to: CGPoint(x: r, y: b + bottomR))
    p.addQuadCurve(to: CGPoint(x: r - bottomR, y: b), control: CGPoint(x: r, y: b))
    p.addLine(to: CGPoint(x: l + bottomR, y: b))
    p.addQuadCurve(to: CGPoint(x: l, y: b + bottomR), control: CGPoint(x: l, y: b))
    p.addLine(to: CGPoint(x: l, y: top - ear))
    p.addQuadCurve(to: CGPoint(x: l - ear, y: top), control: CGPoint(x: l, y: top))
    p.closeSubpath()
    return p
}

func draw(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let s = CGFloat(px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // macOS icon grid: the body is 824/1024 of the canvas, corner radius ~ 185/1024.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.2237
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let u = body.width / 100

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.35))
    ctx.addPath(squircle); ctx.setFillColor(rgb(0x0B3D5C)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x0B3D5C), rgb(0x1F8A9E), rgb(0x7FE0C2)], [0, 0.55, 1]),
                           start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: body.midX, y: body.maxY - 40 * u), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.maxY - 40 * u), endRadius: 46 * u, options: [])
    // The notch
    let notch = notchPath(top: body.maxY, midX: body.midX, width: 74 * u, height: 46 * u, ear: 8 * u, bottomR: 20 * u)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2 * u), blur: 7 * u, color: rgb(0x000000, 0.5))
    ctx.addPath(notch); ctx.setFillColor(rgb(0x050507)); ctx.fillPath()
    ctx.restoreGState()
    // The eyes, glancing to the side
    for dx in [-15.5, 15.5] as [CGFloat] {
        let c = CGPoint(x: body.midX + dx * u, y: body.maxY - 22 * u)
        ctx.addEllipse(in: CGRect(x: c.x - 10 * u, y: c.y - 12.5 * u, width: 20 * u, height: 25 * u))
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
        let pc = CGPoint(x: c.x + 3.6 * u, y: c.y - 2.4 * u)
        ctx.addEllipse(in: CGRect(x: pc.x - 6.4 * u, y: pc.y - 6.4 * u, width: 12.8 * u, height: 12.8 * u))
        ctx.setFillColor(rgb(0x14142B)); ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: pc.x + 0.8 * u, y: pc.y + 1.6 * u, width: 3.8 * u, height: 3.8 * u))
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    }
    ctx.restoreGState()
    ctx.addPath(squircle); ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(max(1, s / 512)); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px: px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
