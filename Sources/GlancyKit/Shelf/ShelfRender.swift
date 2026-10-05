import AppKit
import ImageIO
import UniformTypeIdentifiers

// Shelf states for `glancy-render` (off-screen). Sample files live in the renderer's scratch
// folder; the shelf is changed in memory only (never saved), and `endRender` puts it back.

extension ShelfModule {
    public enum RenderState: String, CaseIterable, Sendable {
        case dropTargets, dropTargetsZip, itemActions, screenshotPeek, downloadPeek
        public var isPeek: Bool { self == .screenshotPeek || self == .downloadPeek }
    }

    public func prepareForRender(_ state: RenderState, scratch: URL) {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        if renderSaved == nil { renderSaved = model.items }
        hideDropTargets()
        model.renderHover = nil
        model.selection = []
        switch state {
        case .dropTargets, .dropTargetsZip:
            model.dropCount = 3
            model.dropTargetsShown = true
            model.dropHover = state == .dropTargets ? .airDrop : .zip
        case .itemActions:
            let names = ["Quarterly report.pdf", "Moodboard.png", "Invoice 0412.pdf", "Notes.txt", "Keynote draft.key", "Budget 2026.xlsx"]
            let items = names.compactMap { name -> ShelfItem? in
                let url = scratch.appendingPathComponent(name)
                if name.hasSuffix(".png") { Self.renderSampleImage(url) } else { try? Data("sample".utf8).write(to: url) }
                return try? ShelfStore.item(for: url, owned: false)
            }
            setItems(items, save: false)
            model.selection = Set(items.prefix(2).map(\.id))
            model.renderHover = items.first?.id
        case .screenshotPeek:
            let url = scratch.appendingPathComponent("Screenshot 2026-10-05 at 09.41.22.png")
            Self.renderSampleImage(url)
            model.lastScreenshot = url
            showScreenshotPeek(url)
        case .downloadPeek:
            let url = scratch.appendingPathComponent("Quarterly report Q3.pdf")
            try? Data("%PDF-1.4".utf8).write(to: url)
            model.lastDownloads = [url]
            showDownloadPeek([url])
        }
    }

    public func endRender() {
        hideDropTargets()
        model.renderHover = nil
        model.selection = []
        if let saved = renderSaved { setItems(saved, save: false) }
        renderSaved = nil
    }

    /// A small "screenshot": a window on a gradient.
    static func renderSampleImage(_ url: URL) {
        let w = 640, h = 400
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let colors = [CGColor(red: 0.42, green: 0.36, blue: 0.95, alpha: 1), CGColor(red: 0.95, green: 0.45, blue: 0.55, alpha: 1)]
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 90, y: 60, width: 460, height: 280), cornerWidth: 18, cornerHeight: 18, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        for i in 0..<4 { ctx.fill(CGRect(x: 120, y: 260 - i * 46, width: 300 - i * 40, height: 16)) }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
