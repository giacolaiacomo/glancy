import AppKit
import SwiftUI

/// What the shelf views render from.
@MainActor @Observable
public final class ShelfModel {
    public internal(set) var items: [ShelfItem] = []
    public var selection: Set<UUID> = []
    /// Promised files still being written by their source app.
    public internal(set) var receiving = 0
    /// Resolved locations, by item; refreshed with the list.
    @ObservationIgnored var urls: [UUID: URL] = [:]
    public init() {}

    public func url(_ item: ShelfItem) -> URL { urls[item.id] ?? URL(fileURLWithPath: item.path) }

    /// The selected items in shelf order, or every item when nothing is selected.
    public var targets: [ShelfItem] {
        let picked = items.filter { selection.contains($0.id) }
        return picked.isEmpty ? items : picked
    }
}

/// Shelf (SPEC §3): files dropped on the notch, kept as bookmarks across relaunches, dragged back
/// out anywhere; AirDrop, Share, Quick Look. Nothing runs at rest: one click monitor (see
/// `ShelfDragWatcher`) and the drop target the surface forwards to.
@MainActor
public final class ShelfModule: GlancyModule, SurfaceDropTarget {
    public let id: ModuleID = .shelf
    public let model = ShelfModel()
    let thumbnails = ShelfThumbnails()

    private let store: ShelfStore
    private var hub: ActivityHub?
    private let watcher = ShelfDragWatcher()
    private var visibility: SurfaceVisibility = .collapsed
    private var openedForDrag = false
    private var droppedThisDrag = false
    private var dragOver = false
    private var dragAcceptable = false
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "ai.glancy.shelf.promises"
        q.qualityOfService = .userInitiated
        return q
    }()
    private var started = false

    /// Files that vanish after the drag and must be copied in (tests point this at their own rule).
    private let isTransient: (URL) -> Bool

    public convenience init() { self.init(store: .default) }

    public init(store: ShelfStore, isTransient: @escaping (URL) -> Bool = ShelfStore.isTransient) {
        self.store = store
        self.isTransient = isTransient
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
    }

    public func stop() {
        started = false
        watcher.stop()
        if SurfaceDrop.target === self { SurfaceDrop.target = nil }
        hub?.clearAll(from: .shelf)
        hub = nil
        thumbnails.removeAll()
    }

    public func visibilityChanged(_ v: SurfaceVisibility) {
        visibility = v
        if case .expanded = v {} else { model.selection = [] }
    }

    // MARK: Drag towards the notch (SPEC §2: within 32 pt opens the Shelf tab)

    private func dragApproached() {
        guard let hub else { return }
        if case .expanded = visibility { openedForDrag = false } else { openedForDrag = true }
        droppedThisDrag = false
        hub.requestOpen(.shelf)
    }

    /// The button went up: if we opened the panel for a drag that was dropped elsewhere, close it.
    /// Checked a moment later: the button-up can reach us before the drop itself does.
    private func dragEnded() {
        guard openedForDrag else { return }
        openedForDrag = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !self.droppedThisDrag, !self.dragOver else { return }
            self.hub?.requestClose()
        }
    }

    // MARK: SurfaceDropTarget

    public var dropTypes: [NSPasteboard.PasteboardType] { ShelfDrop.types }

    public func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        if !dragOver {
            // Judged once per entry. Our own items dragged back over the notch: nothing to add.
            dragOver = true
            dragAcceptable = info.draggingSource == nil && ShelfDrop.classify(info.draggingPasteboard) != nil
            guard dragAcceptable else { return [] }
            let count = max(1, info.numberOfValidItemsForDrop)
            hub?.post(LiveActivity(id: "shelf.drag", module: .shelf, priority: 95,
                                   left: AnyView(ShelfDragWing(count: count)), right: AnyView(EmptyView())))
            if visibility != .expanded(.shelf) { hub?.requestOpen(.shelf) }
        }
        return dragAcceptable ? .copy : []
    }

    public func dragExited() {
        dragOver = false
        hub?.clear("shelf.drag")
    }

    public func performDrop(_ info: NSDraggingInfo) -> Bool {
        dragExited()
        guard info.draggingSource == nil, let kind = ShelfDrop.classify(info.draggingPasteboard) else { return false }
        droppedThisDrag = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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

    private func add(_ files: [(URL, Bool)]) {
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

    private func setItems(_ items: [ShelfItem], save: Bool = true) {
        var urls: [UUID: URL] = [:]
        for item in items { urls[item.id] = ShelfStore.resolve(item)?.0 ?? URL(fileURLWithPath: item.path) }
        model.urls = urls
        model.items = items
        model.selection.formIntersection(items.map(\.id))
        if save { store.save(items) }
    }

    // MARK: Actions on the selection

    func quickLook(from item: ShelfItem? = nil) {
        let targets = model.targets
        guard !targets.isEmpty else { return }
        let start = item.flatMap { i in targets.firstIndex(where: { $0.id == i.id }) } ?? 0
        ShelfQuickLook.shared.show(targets.map { model.url($0) }, at: start)
    }

    func airDrop() {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: model.targets.map { model.url($0) })
    }

    func share(from view: NSView) {
        let picker = NSSharingServicePicker(items: model.targets.map { model.url($0) })
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(model.targets.map { model.url($0) })
    }

    func openShelfTab() { hub?.requestOpen(.shelf) }

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
}
