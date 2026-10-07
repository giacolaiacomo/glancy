import AppKit
import SwiftUI

/// What the shelf views render from.
@MainActor @Observable
public final class ShelfModel {
    public internal(set) var items: [ShelfItem] = []
    public var selection: Set<UUID> = []
    /// Promised files still being written by their source app.
    public internal(set) var receiving = 0
    /// Zips and conversions under way.
    public internal(set) var busy = 0
    /// Resolved locations, by item; refreshed with the list.
    @ObservationIgnored var urls: [UUID: URL] = [:]

    // Drop targets (files dragged to the notch)
    /// The split drop zone is up (a file drag reached the notch).
    public internal(set) var dropTargetsShown = false
    /// The target under the pointer; nil = none (a drop goes to the Shelf).
    public internal(set) var dropHover: ShelfDropAction?
    /// Files in the drag.
    public internal(set) var dropCount = 0
    @ObservationIgnored var dropFrames: [ShelfDropAction: CGRect] = [:]
    @ObservationIgnored weak var dropProbe: NSView?

    // Screenshots and downloads
    public internal(set) var lastScreenshot: URL?
    public internal(set) var lastDownloads: [URL] = []
    public internal(set) var screenshotsStatus: ShelfFolderStatus = .off
    public internal(set) var downloadsStatus: ShelfFolderStatus = .off
    public internal(set) var screenshotsFolder: URL?
    /// Renderer only: the tile drawn as hovered (its "…" showing).
    var renderHover: UUID?

    public init() {}

    public func url(_ item: ShelfItem) -> URL { urls[item.id] ?? URL(fileURLWithPath: item.path) }

    /// The selected items in shelf order, or every item when nothing is selected.
    public var targets: [ShelfItem] {
        let picked = items.filter { selection.contains($0.id) }
        return picked.isEmpty ? items : picked
    }
}

/// Shelf (SPEC §3): files dropped on the notch, kept as bookmarks across relaunches, dragged back
/// out anywhere; AirDrop, Share, Quick Look, Copy, Open with, Zip, image conversion. While files
/// are dragged to the notch the drop zone splits into Shelf / AirDrop / Share / Zip. New
/// screenshots (opt-in) and finished downloads drop down from the notch. Nothing runs at rest:
/// one click monitor (see `ShelfDragWatcher`), the drop target the surface forwards to, and a
/// `DispatchSource` per watched folder.
@MainActor
public final class ShelfModule: GlancyModule, SurfaceDropTarget {
    public let id: ModuleID = .shelf
    public let model = ShelfModel()
    let thumbnails = ShelfThumbnails()

    public let settings: ShelfSettings
    let store: ShelfStore
    let folders: ShelfFolders
    private(set) var hub: ActivityHub?
    var screenshotWatcher: ShelfFolderWatcher?
    var downloadWatcher: ShelfFolderWatcher?
    private let watcher = ShelfDragWatcher()
    private var visibility: SurfaceVisibility = .collapsed
    private var openedForDrag = false
    private var droppedThisDrag = false
    private var dragOver = false
    private var dragAcceptable = false
    private var dragKind: ShelfDropKind?
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "ai.glancy.shelf.promises"
        q.qualityOfService = .userInitiated
        return q
    }()
    private var started = false
    /// Renderer only: the real items while sample ones are shown.
    var renderSaved: [ShelfItem]?

    /// Files that vanish after the drag and must be copied in (tests point this at their own rule).
    private let isTransient: (URL) -> Bool

    public convenience init() { self.init(store: .default, folders: .system) }

    public init(store: ShelfStore, isTransient: @escaping (URL) -> Bool = ShelfStore.isTransient,
                settings: ShelfSettings = ShelfSettings(), folders: ShelfFolders = .none) {
        self.store = store
        self.isTransient = isTransient
        self.settings = settings
        self.folders = folders
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(shelfItalian)
        setItems(store.load(), save: false)
        SurfaceDrop.target = self
        watcher.onApproach = { [weak self] in self?.dragApproached() }
        watcher.onDragEnded = { [weak self] in self?.dragEnded() }
        watcher.start()
        settings.onChange = { [weak self] in self?.applyFolderSettings() }
        applyFolderSettings()
    }

    public func stop() {
        started = false
        watcher.stop()
        settings.onChange = nil
        stopFolderWatchers()
        hideDropTargets()
        if SurfaceDrop.target === self { SurfaceDrop.target = nil }
        hub?.clearAll(from: .shelf)
        hub = nil
        thumbnails.removeAll()
    }

    public func visibilityChanged(_ v: SurfaceVisibility) {
        visibility = v
        if case .expanded = v {
            // The screenshot location is a system preference with no change notification: look
            // again whenever the panel opens (one defaults read).
            if settings.screenshots, let folder = folders.screenshots(), folder != screenshotWatcher?.folder {
                applyFolderSettings()
            }
        } else { model.selection = [] }
    }

    // MARK: Drag towards the notch (SPEC §2: within 32 pt opens the Shelf tab)

    private func dragApproached() {
        guard let hub else { return }
        if case .expanded = visibility { openedForDrag = false } else { openedForDrag = true }
        droppedThisDrag = false
        let files = ShelfDrop.fileCount(NSPasteboard(name: .drag))
        if settings.dropTargets && files > 0 { showDropTargets(count: files) }
        hub.requestOpen(.shelf)
    }

    /// The button went up: if we opened the panel for a drag that was dropped elsewhere, close it.
    /// Checked a moment later: the button-up can reach us before the drop itself does.
    private func dragEnded() {
        let reopen = openedForDrag
        openedForDrag = false
        Task { [weak self] in
            try? await Delay.sleep(for: .milliseconds(400))
            guard let self, !self.dragOver else { return }
            self.hideDropTargets()
            if reopen && !self.droppedThisDrag { self.hub?.requestClose() }
        }
    }

    func showDropTargets(count: Int) {
        if !model.dropTargetsShown { model.dropTargetsShown = true }
        if model.dropCount != count { model.dropCount = count }
    }

    func hideDropTargets() {
        guard model.dropTargetsShown || model.dropHover != nil else { return }
        model.dropTargetsShown = false
        model.dropHover = nil
    }

    /// The target under a drag location given in window coordinates.
    func dropTarget(atWindowPoint p: NSPoint, in window: NSWindow?) -> ShelfDropAction? {
        guard model.dropTargetsShown, let probe = model.dropProbe, probe.window != nil, probe.window === window else { return nil }
        return ShelfDropAction.hit(probe.convert(p, from: nil), frames: model.dropFrames)
    }

    // MARK: SurfaceDropTarget

    public var dropTypes: [NSPasteboard.PasteboardType] { ShelfDrop.types }

    public func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        if !dragOver {
            // Judged once per entry. Our own items dragged back over the notch: nothing to add.
            dragOver = true
            dragKind = info.draggingSource == nil ? ShelfDrop.classify(info.draggingPasteboard) : nil
            dragAcceptable = dragKind != nil
            guard dragAcceptable else { return [] }
            let count = max(1, info.numberOfValidItemsForDrop)
            hub?.post(LiveActivity(id: "shelf.drag", module: .shelf, priority: 95,
                                   left: AnyView(ShelfDragWing(count: count)), right: AnyView(EmptyView())))
            if case .files(let urls) = dragKind, settings.dropTargets { showDropTargets(count: urls.count) }
            if visibility != .expanded(.shelf) { hub?.requestOpen(.shelf) }
        }
        guard dragAcceptable else { return [] }
        // Every move over the panel: which target is under the pointer.
        let hover = dropTarget(atWindowPoint: info.draggingLocation, in: info.draggingDestinationWindow)
        if model.dropHover != hover {
            model.dropHover = hover
            if hover != nil { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        }
        return .copy
    }

    public func dragExited() {
        dragOver = false
        if model.dropHover != nil { model.dropHover = nil }
        hub?.clear("shelf.drag")
        // Left the notch with the button already up (a cancelled drag): nothing more will come.
        if NSEvent.pressedMouseButtons & 1 == 0 { hideDropTargets() }
    }

    public func performDrop(_ info: NSDraggingInfo) -> Bool {
        let action = ShelfDropAction.resolve(model.dropHover, targetsShown: model.dropTargetsShown)
        dragOver = false
        hub?.clear("shelf.drag")
        guard info.draggingSource == nil, let kind = ShelfDrop.classify(info.draggingPasteboard) else {
            hideDropTargets()
            return false
        }
        droppedThisDrag = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if case .files(let urls) = kind, action != .shelf {
            perform(action, on: urls)
            return true
        }
        hideDropTargets()
        switch kind {
        case .files(let urls): addFiles(urls)
        case .promises: receivePromises(from: info.draggingPasteboard)
        case .link(let url): if let staged = try? store.stageLink(url) { add([(staged, true)]) }
        case .text(let text): if let staged = try? store.stageText(text) { add([(staged, true)]) }
        }
        return true
    }

    // MARK: Adding

    /// Files dropped from Finder & co. are bookmarked where they are; files that vanish after the
    /// drag (provider staging, temp folders) are copied in first.
    public func addFiles(_ urls: [URL]) {
        add(urls.compactMap { url in
            guard isTransient(url) else { return (url, false) }
            return (try? store.stageCopy(of: url)).map { ($0, true) }
        })
    }

    func add(_ files: [(URL, Bool)]) {
        let new = files.compactMap { try? ShelfStore.item(for: $0.0, owned: $0.1) }
        guard !new.isEmpty else { return }
        let (items, removed) = ShelfList.adding(new, to: model.items)
        removed.forEach { store.removeStaged($0); thumbnails.forget($0.id) }
        setItems(items)
    }

    /// File promises (Mail, Outlook, Photos): the source app writes each file into its own folder
    /// under `shelf-files/`, then it joins the shelf.
    private func receivePromises(from pb: NSPasteboard) {
        let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        for receiver in receivers {
            guard let folder = try? store.stagingFolder() else { continue }
            model.receiving += 1
            // @Sendable: the reader runs on `promiseQueue`. Without it the closure inherits the
            // main actor and Swift 6 traps on that queue (the app crashed on a Mail/Outlook drop).
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { @Sendable url, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if error == nil, FileManager.default.fileExists(atPath: url.path) { self.add([(url, true)]) }
                    self.model.receiving = max(0, self.model.receiving - 1)
                    // A promise that failed leaves an empty folder behind.
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path), contents.isEmpty {
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
            }
        }
    }

    // MARK: Removing

    public func remove(_ ids: Set<UUID>) {
        let gone = model.items.filter { ids.contains($0.id) }
        gone.forEach { store.removeStaged($0); thumbnails.forget($0.id) }
        model.selection.subtract(ids)
        setItems(model.items.filter { !ids.contains($0.id) })
    }

    public func clear() { remove(Set(model.items.map(\.id))) }

    func setItems(_ items: [ShelfItem], save: Bool = true) {
        var urls: [UUID: URL] = [:]
        for item in items { urls[item.id] = ShelfStore.resolve(item)?.0 ?? URL(fileURLWithPath: item.path) }
        model.urls = urls
        model.items = items
        model.selection.formIntersection(items.map(\.id))
        if save { store.save(items) }
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .shelf, symbol: "tray", title: "Shelf") { [unowned self] in
            AnyView(ShelfTabView(shelf: self, model: model))
        }
    }

    public func homeCard() -> AnyView? {
        guard !model.items.isEmpty else { return nil }
        return AnyView(ShelfHomeCard(shelf: self, model: model))
    }

    /// At rest (Always, empty shelf): a place to drop files. A drag onto the panel lands on the
    /// shelf as anywhere on the notch; a click opens it.
    public func homeIdleCard(_ widget: HomeWidget) -> AnyView? {
        guard widget == .shelf, model.items.isEmpty else { return nil }
        return AnyView(HomeIdleRow(symbol: "tray.and.arrow.down", caption: L10n.tr("Shelf"), title: L10n.tr("Drop files here"),
                                   detail: L10n.tr("They stay until you remove them"),
                                   open: { [weak self] in self?.openShelfTab() }))
    }
}
