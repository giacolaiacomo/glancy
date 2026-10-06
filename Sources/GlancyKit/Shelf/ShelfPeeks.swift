import AppKit
import ImageIO
import SwiftUI

// The drop-downs for a new screenshot and a finished download (≤ 32 pt tall, ≤ 384 pt wide).
// Buttons and the draggable thumbnail are real AppKit views: on the collapsed surface every other
// click opens the panel before SwiftUI sees it.

struct ShelfScreenshotPeek: View {
    let shelf: ShelfModule
    let url: URL

    var body: some View {
        HStack(spacing: 8.ui) {
            ShelfPeekThumb(url: url, size: CGSize(width: 46.ui, height: 28.ui))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: L10n.tr("Screenshot"))
                    .font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                Text(verbatim: L10n.tr("Drag it anywhere"))
                    .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .fixedSize()
            Spacer(minLength: 6.ui)
            HStack(spacing: 3.ui) {
                ShelfPeekButton(symbol: "doc.on.doc", help: L10n.tr("Copy")) { shelf.copyImage(url) }
                ShelfPeekButton(symbol: "pencil.tip.crop.circle", help: L10n.tr("Annotate")) { shelf.annotate(url) }
                ShelfPeekButton(symbol: "tray.and.arrow.down", help: L10n.tr("Keep on the shelf")) { shelf.keep(url) }
                ShelfPeekButton(symbol: "trash", help: L10n.tr("Delete")) { shelf.trash(url) }
            }
        }
        .frame(width: 290.ui)
    }
}

struct ShelfDownloadPeek: View {
    let shelf: ShelfModule
    let urls: [URL]

    var body: some View {
        let one = urls.count == 1 ? urls.first : nil
        HStack(spacing: 8.ui) {
            ShelfPeekThumb(url: urls[0], urls: urls, size: CGSize(width: 24.ui, height: 24.ui), icon: true)
            HStack(spacing: 4.ui) {
                Text(verbatim: L10n.tr("Downloaded"))
                    .font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                Text(verbatim: one?.lastPathComponent ?? ShelfText.files(urls.count))
                    .font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .frame(maxWidth: 220.ui, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6.ui)
            HStack(spacing: 3.ui) {
                if let one {
                    ShelfPeekButton(title: L10n.tr("Open"), help: L10n.tr("Open")) {
                        NSWorkspace.shared.open(one)
                        shelf.hub?.requestClose()
                    }
                }
                ShelfPeekButton(symbol: "folder", help: L10n.tr("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                ShelfPeekButton(symbol: "tray.and.arrow.down", help: L10n.tr("Keep on the shelf")) {
                    shelf.add(urls.map { ($0, false) })
                    shelf.note(symbol: "tray.and.arrow.down.fill", L10n.tr("On the shelf"))
                }
            }
        }
        .frame(minWidth: 250.ui)
    }
}

/// A one-line note (copied, couldn't zip…).
struct ShelfNotePeek: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 7.ui) {
            Image(systemName: symbol).font(.system(size: 12.ui, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(verbatim: text).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
        }
        .fixedSize()
    }
}

/// A small thumbnail (or the file's icon) that drags the file(s) out.
struct ShelfPeekThumb: View {
    let url: URL
    var urls: [URL]? = nil
    let size: CGSize
    var icon = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(contentMode: icon ? .fit : .fill)
            } else {
                Theme.card
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: icon ? 0 : 5.ui, style: .continuous))
        .overlay {
            if !icon { RoundedRectangle(cornerRadius: 5.ui, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1.ui) }
        }
        .overlay(ShelfMouseArea(onDrag: { view, event in
            let all = urls ?? [url]
            ShelfDragSource.shared.begin(urls: all, images: all.map { _ in image ?? NSWorkspace.shared.icon(forFile: url.path) },
                                         from: view, event: event)
        }))
        .help(url.lastPathComponent)
        .task(id: url) {
            if icon { image = NSWorkspace.shared.icon(forFile: url.path); return }
            let path = url
            let cg = await Task.detached(priority: .userInitiated) { ShelfPeekThumb.downsample(path, maxPixels: 120) }.value
            image = cg.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / 2, height: CGFloat($0.height) / 2)) }
                ?? NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    nonisolated static func downsample(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// An icon (or short text) button that works on the collapsed surface.
struct ShelfPeekButton: View {
    var symbol: String? = nil
    var title: String? = nil
    let help: String
    let action: @MainActor () -> Void
    @State private var hover = false

    var body: some View {
        Group {
            if let title {
                Text(verbatim: title).font(Theme.font(.s, .semibold)).padding(.horizontal, 9.ui)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 11.ui, weight: .medium)).frame(width: 24.ui)
            }
        }
        .foregroundStyle(hover ? Theme.primary : Theme.secondary)
        .frame(height: 22.ui)
        .background(Capsule().fill(hover ? Theme.hairline : Theme.card))
        .overlay(ShelfClickTarget(action: action))
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(.isButton)
    }
}

/// A real NSView over a button: it gets its own clicks (first click included), so the button
/// acts while the rest of a collapsed peek still opens the panel.
struct ShelfClickTarget: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView(action: action) }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }

    final class ClickView: NSView {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("unused") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
        }
    }
}
