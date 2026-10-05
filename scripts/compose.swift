// Composes the README images from glancy-render --demo output (made-up data only).
// Usage: swift scripts/compose.swift <renders dir> <icon.png> <out dir>
// Reads 02-activity.png, 05-expanded-home.png and the 06-tab-* renders (900×290 pt at 2×).
// Writes hero.png (1280×640 pt) and screens.png (1280 pt wide), both at 2×.

import AppKit

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), iconURL = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])

func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

/// A render at point size (renders are @2x).
func load(_ name: String) -> NSImage {
    let img = NSImage(contentsOf: src.appendingPathComponent(name))!
    let rep = img.representations[0]
    img.size = NSSize(width: rep.pixelsWide / 2, height: rep.pixelsHigh / 2)
    return img
}

/// Draws into a 2× bitmap with a top-left origin, like a screen.
func canvas(_ w: CGFloat, _ h: CGFloat, _ name: String, _ draw: (NSRect) -> Void) {
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: h)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func text(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white, width: CGFloat = 1000) {
    let para = NSMutableParagraphStyle()
    para.lineSpacing = size * 0.22
    let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para])
    let bounds = attr.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin])
    attr.draw(with: NSRect(x: p.x, y: p.y, width: width, height: bounds.height), options: [.usesLineFragmentOrigin])
}

func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
}

/// Part of a render (`crop` in its points, top-left origin) drawn as a rounded "screen" with a shadow.
func screen(_ img: NSImage, crop: NSRect, in r: NSRect, radius: CGFloat = 14) {
    let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.45)
    sh.shadowBlurRadius = 36
    sh.shadowOffset = NSSize(width: 0, height: 16)
    sh.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // NSImage's source rect is bottom-left based.
    let from = NSRect(x: crop.minX, y: img.size.height - crop.maxY, width: crop.width, height: crop.height)
    img.draw(in: r, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.16).setStroke()
    shape.lineWidth = 1
    shape.stroke()
}

func duskBackground(_ r: NSRect) {
    NSGradient(colors: [rgb(0x0E0F1E), rgb(0x1C1636), rgb(0x2A1838)])!.draw(in: r, angle: -55)
    NSGradient(colors: [rgb(0x6F5BFF, 0.34), rgb(0x6F5BFF, 0)])!
        .draw(fromCenter: NSPoint(x: r.width * 0.70, y: r.height * 0.42), radius: 0,
              toCenter: NSPoint(x: r.width * 0.70, y: r.height * 0.42), radius: r.width * 0.55, options: [])
    NSGradient(colors: [rgb(0xFF8A5B, 0.26), rgb(0xFF8A5B, 0)])!
        .draw(fromCenter: NSPoint(x: r.width * 0.08, y: r.height), radius: 0,
              toCenter: NSPoint(x: r.width * 0.08, y: r.height), radius: r.width * 0.45, options: [])
}

let icon = NSImage(contentsOf: iconURL)!
let activity = load("02-activity.png"), home = load("05-expanded-home.png")
let W = activity.size.width   // 900

// MARK: hero.png — brand on the left; the notch with a live activity, and opened, on the right

canvas(1280, 640, "hero.png") { r in
    duskBackground(r)
    let left: CGFloat = 72
    icon.draw(in: NSRect(x: left - 14, y: 96, width: 150, height: 150), from: .zero, operation: .sourceOver, fraction: 1,
              respectFlipped: true, hints: nil)
    text("Glancy", at: NSPoint(x: left, y: 246), size: 72, weight: .heavy)
    text("Your MacBook's notch, put to work:\nClaude Code agents, meetings, music,\nclipboard and windows at a glance.",
         at: NSPoint(x: left, y: 338), size: 21, weight: .medium, color: NSColor.white.withAlphaComponent(0.78), width: 470)
    var cx = left
    for chip in ["~19 MB RAM", "0% CPU idle", "Local only", "Native Swift"] {
        let w = textWidth(chip, size: 14, weight: .semibold) + 24
        let c = NSRect(x: cx, y: 470, width: w, height: 30)
        rgb(0x8A7BFF, 0.18).setFill()
        NSBezierPath(roundedRect: c, xRadius: 15, yRadius: 15).fill()
        rgb(0xA99DFF, 0.55).setStroke()
        NSBezierPath(roundedRect: c.insetBy(dx: 0.5, dy: 0.5), xRadius: 15, yRadius: 15).stroke()
        text(chip, at: NSPoint(x: cx + 12, y: 475.5), size: 14, weight: .semibold, color: rgb(0xDCD6FF))
        cx += w + 9
    }
    // Right column: crops of the 900 pt renders (centred on the notch), centred vertically.
    let colW: CGFloat = 700, colX = r.width - colW - 48, k = colW / W
    let actH: CGFloat = 70, homeH: CGFloat = 236, label: CGFloat = 26, gap: CGFloat = 34
    var y = (r.height - (label + actH * k + gap + label + homeH * k)) / 2
    text("Collapsed: a live activity in the wings", at: NSPoint(x: colX + 4, y: y), size: 14, weight: .semibold,
         color: NSColor.white.withAlphaComponent(0.6))
    y += label
    screen(activity, crop: NSRect(x: 0, y: 0, width: W, height: actH), in: NSRect(x: colX, y: y, width: colW, height: actH * k))
    y += actH * k + gap
    text("Open: Home, with every module's card", at: NSPoint(x: colX + 4, y: y), size: 14, weight: .semibold,
         color: NSColor.white.withAlphaComponent(0.6))
    y += label
    screen(home, crop: NSRect(x: 0, y: 0, width: W, height: homeH), in: NSRect(x: colX, y: y, width: colW, height: homeH * k))
}

// MARK: screens.png — six tabs, two columns

let tabs: [(String, String)] = [
    ("05-expanded-home.png", "Home"), ("06-tab-1-agents.png", "Agents"),
    ("06-tab-2-calendar.png", "Calendar"), ("06-tab-3-media.png", "Media"),
    ("06-tab-6-clipboard.png", "Clipboard"), ("06-tab-7-windows.png", "Windows"),
]
let cellW: CGFloat = 576, cropH: CGFloat = 228, k = cellW / W, cellH = cropH * k
let gapX: CGFloat = 40, top: CGFloat = 44, rowGap: CGFloat = 64
let screensH = top + 3 * cellH + 2 * rowGap + 70
canvas(1280, screensH, "screens.png") { r in
    duskBackground(r)
    let x0 = (r.width - 2 * cellW - gapX) / 2
    for (i, (file, caption)) in tabs.enumerated() {
        let col = CGFloat(i % 2), row = CGFloat(i / 2)
        let x = x0 + col * (cellW + gapX), y = top + row * (cellH + rowGap)
        screen(load(file), crop: NSRect(x: 0, y: 0, width: W, height: cropH), in: NSRect(x: x, y: y, width: cellW, height: cellH))
        let w = textWidth(caption, size: 16, weight: .semibold)
        text(caption, at: NSPoint(x: x + (cellW - w) / 2, y: y + cellH + 14), size: 16, weight: .semibold,
             color: NSColor.white.withAlphaComponent(0.8))
    }
}
print("✓ wrote hero.png and screens.png to \(out.path)")
