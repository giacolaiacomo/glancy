import AppKit
import SwiftUI

// What the shelf does with files: on its items (toolbar, right-click / hover menu, command bar)
// and on files dropped on a drop target. Nothing here touches a file unless asked; nothing is
// ever overwritten or moved — the only deletion is "Delete" on a screenshot peek, to the Trash.

extension ShelfModule {
    // MARK: Targets

    /// URLs of `items`, or of the selection (every item when nothing is selected).
    func urls(_ items: [ShelfItem]? = nil) -> [URL] { (items ?? model.targets).map { model.url($0) } }

    /// The items a menu opened on `item` acts on: the selection if the item is in it, otherwise
    /// the item alone (and it becomes the selection, as in Finder).
    func menuTargets(for item: ShelfItem?) -> [ShelfItem] {
        guard let item else { return model.targets }
        if model.selection.contains(item.id) { return model.items.filter { model.selection.contains($0.id) } }
        model.selection = [item.id]
        return [item]
    }

    // MARK: Item actions

    func quickLook(from item: ShelfItem? = nil) {
        let targets = model.targets
        guard !targets.isEmpty else { return }
        let start = item.flatMap { i in targets.firstIndex(where: { $0.id == i.id }) } ?? 0
        ShelfQuickLook.shared.show(targets.map { model.url($0) }, at: start)
    }

    func airDrop(_ items: [ShelfItem]? = nil) { Self.airDrop(urls(items)) }

    func share(from view: NSView, _ items: [ShelfItem]? = nil) {
        Self.share(urls(items), relativeTo: view.bounds, of: view)
    }

    func reveal(_ items: [ShelfItem]? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting(urls(items))
    }

    func copy(_ items: [ShelfItem]? = nil) { Self.copy(urls(items)) }

    func open(_ items: [ShelfItem]? = nil) {
        for url in urls(items) { NSWorkspace.shared.open(url) }
    }

    func open(_ items: [ShelfItem]?, with app: URL) {
        NSWorkspace.shared.open(urls(items), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func openShelfTab() { hub?.requestOpen(.shelf) }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        // Glancy is an accessory app: the AirDrop window comes up in front only if Glancy is active.
        NSApp.activate()
        service.perform(withItems: urls)
    }

    static func share(_ urls: [URL], relativeTo rect: CGRect, of view: NSView) {
        guard !urls.isEmpty else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    /// Files on the clipboard as Finder puts them (paste in Finder, Mail, Slack…).
    static func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    // MARK: Zip and convert (off main)

    /// Zips the files beside the first one (Finder's Compress), or into the shelf when that
    /// folder is read-only; the archive joins the shelf.
    func zip(_ items: [ShelfItem]? = nil) { zip(urls: urls(items)) }

    func zip(urls sources: [URL]) {
        guard !sources.isEmpty, let (folder, owned) = outputFolder(beside: sources) else { return }
        model.busy += 1
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try ShelfFileOps.zip(sources, into: folder) }
            await self?.finished([result], owned: owned, folder: folder, failure: "Couldn't create the archive")
        }
    }

    func convert(_ items: [ShelfItem]? = nil, _ conversion: ShelfFileOps.Conversion) {
        let images = urls(items).filter(ShelfFileOps.isImage)
        guard !images.isEmpty, let (folder, owned) = outputFolder(beside: images) else { return }
        model.busy += 1
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = images.map { src in Result { try ShelfFileOps.convert(src, conversion, into: folder) } }
            await self?.finished(results, owned: owned, folder: folder, failure: "Couldn't convert the image")
        }
    }

    private func outputFolder(beside sources: [URL]) -> (URL, Bool)? {
        if let beside = ShelfFileOps.outputFolder(beside: sources, staging: store.filesDir) { return (beside, false) }
        return (try? store.stagingFolder()).map { ($0, true) }
    }

    private func finished(_ results: [Result<URL, Error>], owned: Bool, folder: URL, failure: String) {
        model.busy = max(0, model.busy - 1)
        let made = results.compactMap { try? $0.get() }
        if !made.isEmpty {
            add(made.map { ($0, owned) })
            let keys = Set(made.map { ShelfList.key($0.path) })
            let ids = Set(model.items.filter { keys.contains(ShelfList.key($0.path)) }.map(\.id))
            if !ids.isEmpty { model.selection = ids }
        }
        if made.count < results.count {
            note(symbol: "exclamationmark.triangle", L10n.tr(failure))
            if owned, made.isEmpty { try? FileManager.default.removeItem(at: folder) }
        }
    }

    func note(symbol: String, _ text: String) {
        hub?.show(PeekEvent(module: .shelf, duration: 2.5, content: AnyView(ShelfNotePeek(symbol: symbol, text: text))))
    }

    // MARK: Drop targets

    /// Files dropped on AirDrop / Share / Zip. The targets stay up until the share picker has
    /// its anchor; the rest act at once.
    func perform(_ action: ShelfDropAction, on files: [URL]) {
        switch action {
        case .shelf:
            hideDropTargets()
            addFiles(files)
        case .airDrop:
            hideDropTargets()
            Self.airDrop(files)
        case .zip:
            hideDropTargets()
            zip(urls: files)
        case .share:
            // After the drag session has finished (a menu inside performDragOperation would hold
            // the source app's drag), anchored on the Share tile while it is still on screen.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let probe = model.dropProbe, probe.window != nil, let rect = model.dropFrames[.share] {
                    Self.share(files, relativeTo: rect, of: probe)
                }
                hideDropTargets()
            }
        }
    }

    // MARK: Menu (right-click, hover "…", toolbar "…")

    func menu(for item: ShelfItem?) -> NSMenu {
        let targets = menuTargets(for: item)
        let urls = targets.map { model.url($0) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let n = targets.count
        menu.addItem(ShelfMenuItem(L10n.tr("Quick Look"), "eye") { [weak self] in self?.quickLook(from: item) })
        menu.addItem(ShelfMenuItem(L10n.tr("Open"), "arrow.up.forward.app") { [weak self] in self?.open(targets) })
        if let first = urls.first {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: first).prefix(12)
            if !apps.isEmpty {
                let sub = NSMenu()
                for app in apps {
                    let entry = ShelfMenuItem(FileManager.default.displayName(atPath: app.path), nil) { [weak self] in
                        self?.open(targets, with: app)
                    }
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                    sub.addItem(entry)
                }
                let openWith = ShelfMenuItem(L10n.tr("Open With"), "square.grid.2x2", nil)
                openWith.submenu = sub
                menu.addItem(openWith)
            }
        }
        menu.addItem(.separator())
        let share = NSSharingServicePicker(items: urls).standardShareMenuItem
        share.title = L10n.tr("Share")
        menu.addItem(share)
        menu.addItem(ShelfMenuItem(L10n.tr("AirDrop"), "dot.radiowaves.left.and.right") { Self.airDrop(urls) })
        menu.addItem(ShelfMenuItem(n == 1 ? L10n.tr("Copy") : L10n.tr("Copy %d items", n), "doc.on.doc") { Self.copy(urls) })
        menu.addItem(ShelfMenuItem(L10n.tr("Show in Finder"), "folder") { [weak self] in self?.reveal(targets) })
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem(n == 1 ? L10n.tr("Zip") : L10n.tr("Zip %d items", n), "doc.zipper") { [weak self] in
            self?.zip(targets)
        })
        if urls.contains(where: ShelfFileOps.isImage) {
            menu.addItem(ShelfMenuItem(L10n.tr("Convert to JPEG"), "photo") { [weak self] in self?.convert(targets, .jpeg) })
            menu.addItem(ShelfMenuItem(L10n.tr("Resize to 50%"), "arrow.down.right.and.arrow.up.left") { [weak self] in
                self?.convert(targets, .half)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ShelfMenuItem(n == 1 ? L10n.tr("Remove from Shelf") : L10n.tr("Remove %d from Shelf", n), "minus.circle") { [weak self] in
            self?.remove(Set(targets.map(\.id)))
        })
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor
final class ShelfMenuItem: NSMenuItem {
    private let handler: (@MainActor () -> Void)?

    init(_ title: String, _ symbol: String?, _ handler: (@MainActor () -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler?() }
}
