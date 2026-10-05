import AppKit
import QuickLookThumbnailing
import Quartz

/// Shelf thumbnails: QuickLook at 64 px, kept in a count-capped `NSCache` (SPEC §1 "bounded
/// cache"); the Finder icon stands in until (or if never) one arrives.
@MainActor
final class ShelfThumbnails {
    static let pixels: CGFloat = 64
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = ShelfStore.limit + 8
        return c
    }()

    func cached(_ id: UUID) -> NSImage? { cache.object(forKey: id.uuidString as NSString) }

    func image(for id: UUID, url: URL) async -> NSImage {
        if let hit = cached(id) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.pixels / 2, height: Self.pixels / 2),
                                                   scale: 2, representationTypes: [.icon, .thumbnail])
        let cg: CGImage? = await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep?.cgImage)
            }
        }
        let image: NSImage
        if let cg {
            image = NSImage(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache.setObject(image, forKey: id.uuidString as NSString)
        return image
    }

    func forget(_ id: UUID) { cache.removeObject(forKey: id.uuidString as NSString) }
    func removeAll() { cache.removeAllObjects() }
}

/// Quick Look for shelf items. Glancy's panel never becomes key, so the preview panel is driven
/// directly (data source set here) and Glancy activates for as long as it is up.
@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL], at index: Int) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(0, index), urls.count - 1)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] : nil }
        return url as NSURL?
    }
}

/// The source of drags out of the shelf: long-lived, so a drag survives the panel collapsing under
/// it. Copy only — the shelf never moves the user's files.
@MainActor
final class ShelfDragSource: NSObject, NSDraggingSource {
    static let shared = ShelfDragSource()

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// Starts one session with a dragging item per URL (multi-select drags out together).
    func begin(urls: [URL], images: [NSImage], from view: NSView, event: NSEvent) {
        guard !urls.isEmpty else { return }
        let origin = view.convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.enumerated().map { i, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = i < images.count ? images[i] : NSWorkspace.shared.icon(forFile: url.path)
            let side: CGFloat = 40
            let offset = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(CGRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side),
                                  contents: image)
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }
}
