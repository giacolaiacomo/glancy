import AppKit
import Observation
import SwiftUI

/// The Settings window (SPEC §4): a sidebar (General, Home, Permissions, one row per module, About)
/// and the selected page. One at a time; opening it again brings it forward. Built when opened and
/// released when closed: the window, its split view and both hosting controllers go, and memory is
/// handed back a few seconds later (`MemoryRelief`), so the idle footprint returns to its baseline.
///
/// Opened from the notch's gear (the panel collapses), ⌘, while Glancy is active (`SettingsMenu`),
/// the command bar and the first-run welcome — all through `SurfaceRoute.openSettings` or `show`.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    /// How the window is put on screen.
    enum Mode {
        /// The app: activates Glancy and brings the window forward.
        case app
        /// `--lab`: real and ordered in, but 20 000 pt off every display, never activating anything.
        case lab
        /// Tests and renders: built and laid out, never ordered in.
        case offscreen
    }

    /// The open window, if any (one per app).
    public private(set) static var current: SettingsWindowController?
    /// Memory relief after a close (cancelled by a reopen first).
    private static var reliefTask: Task<Void, Never>?
    static let reliefDelay: Duration = .seconds(3)

    public static let defaultSize = NSSize(width: 820, height: 660)
    public static let minimumSize = NSSize(width: 720, height: 520)
    static let sidebarWidth: CGFloat = 220

    let context: SurfaceContext
    let mode: Mode
    let window: SettingsWindowFrame
    private let crashes: CrashLog
    private var closed = false

    // MARK: Opening

    /// Opens the window on `route` (nil = the page it was on), or brings it forward. `welcome`
    /// shows Permissions as the first-run welcome.
    @discardableResult
    public static func show(_ route: SettingsRoute? = nil, context: SurfaceContext, welcome: Bool = false) -> SettingsWindowController {
        show(route, context: context, welcome: welcome, mode: Lab.isActive ? .lab : .app)
    }

    @discardableResult
    static func show(_ route: SettingsRoute?, context: SurfaceContext, welcome: Bool = false, mode: Mode,
                     crashes: CrashLog = CrashLog()) -> SettingsWindowController {
        reliefTask?.cancel(); reliefTask = nil
        let nav = context.settings.navigation
        if welcome { nav.showWelcome() } else if let route { nav.go(route) }
        nav.go(SettingsSidebar.resolve(nav.route, registered: Set(context.modules.map(\.id))))
        if let current, current.context === context, !current.closed {
            current.present()
            return current
        }
        current?.window.close()
        let controller = SettingsWindowController(context: context, mode: mode, crashes: crashes)
        current = controller
        controller.present()
        return controller
    }

    /// Closes the open window, if any.
    public static func closeCurrent() { current?.close() }

    private init(context: SurfaceContext, mode: Mode, crashes: CrashLog) {
        self.context = context
        self.mode = mode
        self.crashes = crashes
        window = SettingsWindowFrame(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: mode == .app)
        super.init()
        build()
    }

    private func build() {
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenNone, .managed]
        window.contentMinSize = Self.minimumSize
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.keepsFrame = mode == .lab
        window.drawsAsKey = mode == .offscreen

        let split = NSSplitViewController()
        let sidebar = NSHostingController(rootView: SettingsSidebarView(context: context))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 280
        sidebarItem.holdingPriority = .defaultLow + 10
        let detail = NSHostingController(rootView: SettingsDetailView(context: context, crashes: crashes) { [weak self] in
            self?.close()
        })
        detail.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 480
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        window.contentViewController = split
        window.setContentSize(Self.defaultSize)
        split.splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)

        let toolbar = NSToolbar(identifier: "GlancySettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        switch mode {
        case .app:
            window.center()
            // Remembers where the user put it, and the sidebar's width.
            window.setFrameAutosaveName("GlancySettings")
            split.splitView.autosaveName = "GlancySettingsSidebar"
        case .lab:
            window.setFrameOrigin(NSPoint(x: Lab.offset, y: 200))
        case .offscreen:
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        }
        observeTitle()
    }

    /// Brings the window forward (activating Glancy in the app; never in the lab or a render).
    private func present() {
        switch mode {
        case .app:
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeFirstResponder(nil)
        case .lab:
            window.orderFrontRegardless()
        case .offscreen:
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Closing

    public func close() {
        guard !closed else { return }
        window.close()            // → windowWillClose → tearDown
        tearDown()
    }

    public func windowWillClose(_ notification: Notification) { tearDown() }

    /// Drops everything the window holds: the hosting controllers go with the split view.
    private func tearDown() {
        guard !closed else { return }
        closed = true
        HotkeyRecorder.shared.end()
        context.settings.navigation.welcome = false
        window.delegate = nil
        window.toolbar = nil
        window.contentViewController = nil
        if Self.current === self { Self.current = nil }
        if mode == .app {
            // Back to the app the user was in (Glancy has no other window of its own).
            let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
            if NSApp.isActive, !others { NSApp.deactivate() }
        }
        // Tests and renders have nothing to hand back (and MemoryRelief is process-wide).
        if mode != .offscreen { Self.scheduleRelief() }
    }

    /// An idle Glancy gets no events, and AppKit drains its autorelease pool (and drops its last
    /// event, which points at the window) only after the next one: until the user's next click the
    /// closed window and its pages would stay alive. One application-defined event lets go of them.
    private static func drainEventLoop() {
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                             context: nil, subtype: 0, data1: 0, data2: 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// A few seconds after the close (what closing autoreleased has settled by then): the event
    /// that drains AppKit's pool, then the malloc relief once the window is gone.
    private static func scheduleRelief() {
        reliefTask?.cancel()
        reliefTask = Task { @MainActor in
            try? await Delay.sleep(for: reliefDelay)
            guard !Task.isCancelled, current == nil else { return }
            drainEventLoop()
            try? await Delay.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, current == nil else { return }
            reliefTask = nil
            MemoryRelief.run()
        }
    }

    /// Tests: whether the window is still held.
    var isClosed: Bool { closed }

    // MARK: Title

    /// The toolbar shows the page's name (re-read when the page or the language changes).
    private func observeTitle() {
        guard !closed else { return }
        let nav = context.settings.navigation
        let title = withObservationTracking {
            _ = context.settings.language
            return nav.welcome ? "Glancy" : SettingsSidebar.title(nav.route)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTitle() }
        }
        if window.title != title { window.title = title }
    }

    // MARK: Toolbar (only the sidebar's tracking separator: the title sits over the page)

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
}

/// The Settings window itself. Lab: stays where it is put (off every display). Renders: draws as
/// the key window. ⌘W closes it; the editing keys reach the search field (Glancy's menu bar has no
/// Edit menu).
final class SettingsWindowFrame: NSWindow {
    var keepsFrame = false
    var drawsAsKey = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        keepsFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override var isKeyWindow: Bool { drawsAsKey || super.isKeyWindow }
    override var isMainWindow: Bool { drawsAsKey || super.isMainWindow }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command || mods == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: Selector? = switch (key, mods == .command) {
        case ("w", true): #selector(NSWindow.performClose(_:))
        case ("x", true): #selector(NSText.cut(_:))
        case ("c", true): #selector(NSText.copy(_:))
        case ("v", true): #selector(NSText.paste(_:))
        case ("a", true): #selector(NSText.selectAll(_:))
        case ("z", true): Selector(("undo:"))
        case ("z", false): Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

// MARK: - Renders

extension SettingsWindowController {
    /// glancy-render: the window on a page, built off-screen (never ordered in, nothing activated),
    /// drawn as the key window in light or dark at 2×, with its rounded corners and shadow over a
    /// plain backdrop. `crashes` stands in for the crash reports on About.
    public static func snapshot(_ route: SettingsRoute, context: SurfaceContext, welcome: Bool = false, dark: Bool,
                                size: NSSize = defaultSize, crashes: [(date: String, exception: String)] = [],
                                version: String = "0.4.0 (4000)", icon: NSImage? = nil) -> NSBitmapImageRep? {
        closeCurrent()
        AboutInfo.versionOverride = version
        AboutInfo.iconOverride = icon
        defer { AboutInfo.versionOverride = nil; AboutInfo.iconOverride = nil }
        let entries = crashes.map { CrashLog.Entry(date: $0.date, exception: $0.exception,
                                                   url: URL(fileURLWithPath: "/tmp/\($0.date).txt")) }
        let log = CrashLog.fixed(entries)
        let controller = show(route, context: context, welcome: welcome, mode: .offscreen, crashes: log)
        defer { controller.close() }
        let window = controller.window
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        (window.contentViewController as? NSSplitViewController)?.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        }
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.layoutSubtreeIfNeeded()
        frameView.display()
        let bounds = frameView.bounds
        guard let inside = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let split = window.contentViewController as? NSSplitViewController else { return nil }
        inside.size = bounds.size     // before the context: it then works in points
        guard let g = NSGraphicsContext(bitmapImageRep: inside) else { return nil }
        // An off-screen capture leaves out what the window server composes: the sidebar's glass
        // and what sits on it, and a SwiftUI scroll view's content. Those parts are captured one by
        // one and laid over the window's own capture, the glass painted in its colours.
        frameView.cacheDisplay(in: bounds, to: inside)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = g
        func paste(_ view: NSView, clip: NSRect? = nil) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let rect = view.convert(view.bounds, to: frameView)
            g.cgContext.saveGState()
            if let clip { g.cgContext.clip(to: rect.intersection(clip)) }
            rep.draw(in: rect)
            g.cgContext.restoreGState()
        }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            var panel: NSRect?
            if let sidebar = split.splitViewItems.first?.viewController.view,
               let wrapper = split.splitView.subviews.first(where: { sidebar.isDescendant(of: $0) }) {
                NSColor.windowBackgroundColor.setFill()
                wrapper.convert(wrapper.bounds, to: frameView).fill()
                let glass = descendants(of: wrapper).first { "\(type(of: $0))".contains("Glass") }
                panel = glass.map { $0.convert($0.bounds, to: frameView) } ?? wrapper.convert(wrapper.bounds, to: frameView).insetBy(dx: 8, dy: 8)
                paste(sidebar)
            }
            let page = split.splitViewItems.last?.viewController.view
            for clip in page.map(descendants(of:))?.compactMap({ $0 as? NSClipView }) ?? [] {
                paste(clip, clip: window.contentLayoutRect)
            }
            if let titlebar = frameView.subviews.first(where: { "\(type(of: $0))".contains("Titlebar") }) {
                paste(titlebar)
            }
            // The sidebar's glass, up to the top (the window buttons sit on it): tinted over what
            // is drawn (darker in light, lighter in dark), outlined.
            if let panel {
                let shape = NSBezierPath(roundedRect: panel, xRadius: 18, yRadius: 18)
                g.cgContext.saveGState()
                g.cgContext.setBlendMode(dark ? .lighten : .darken)
                (dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                shape.fill()
                g.cgContext.restoreGState()
                (dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.08)).setStroke()
                shape.lineWidth = 1
                shape.stroke()
            }
        }
        return framed(inside, dark: dark)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The capture with the window's corners, edge and shadow over a backdrop, 32 pt around it.
    private static func framed(_ inside: NSBitmapImageRep, dark: Bool) -> NSBitmapImageRep? {
        let margin: CGFloat = 32, radius: CGFloat = 26
        let size = NSSize(width: inside.size.width + margin * 2, height: inside.size.height + margin * 2)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let image = inside.cgImage else { return nil }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let g = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.current = g
        let ctx = g.cgContext
        ctx.setFillColor(dark ? CGColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1) : CGColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let rect = CGRect(x: margin, y: margin, width: inside.size.width, height: inside.size.height)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.28))
        ctx.addPath(path)
        ctx.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 0, alpha: 0.14))
        ctx.setLineWidth(1)
        ctx.strokePath()
        return out
    }
}

// MARK: - Menu

/// Glancy's menu bar while it is active (it is an accessory app: the bar is not shown, but its key
/// equivalents work): "Settings…" ⌘, only. No ⌘Q: the notch panel takes the keyboard without
/// activating Glancy, and ⌘Q there must keep quitting the app in front, not Glancy.
@MainActor
public enum SettingsMenu {
    private static var target: MenuTarget?

    public static func install(open: @escaping @MainActor () -> Void) {
        let t = MenuTarget(open: open)
        target = t
        NSApp.mainMenu = make(target: t)
    }

    static func make(target: MenuTarget) -> NSMenu {
        let main = NSMenu(title: "Glancy")
        let appItem = NSMenuItem(title: "Glancy", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Glancy")
        let settings = NSMenuItem(title: tr("Settings…"), action: #selector(MenuTarget.openSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = target
        appMenu.addItem(settings)
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }

    @MainActor
    final class MenuTarget: NSObject {
        let open: @MainActor () -> Void
        init(open: @escaping @MainActor () -> Void) { self.open = open }
        /// AppKit sends menu actions on the main thread.
        @objc nonisolated func openSettings(_ sender: Any?) { MainActor.assumeIsolated { open() } }
    }
}

// MARK: - Sidebar

/// General, Home, Permissions; one row per registered module (dimmed when off); About. A search
/// field on top filters the rows by page and row names.
struct SettingsSidebarView: View {
    let context: SurfaceContext
    @State private var query = ""

    var body: some View {
        let settings = context.settings
        let nav = settings.navigation
        let registered = Set(context.modules.map(\.id))
        let top = [SettingsRoute.general, .home, .permissions].filter { SettingsSidebar.matches($0, query: query) }
        let modules = SettingsSidebar.modules(registered: registered).filter { SettingsSidebar.matches(.module($0), query: query) }
        let about = SettingsSidebar.matches(.about, query: query)
        let missing = PermissionRows.missing(context)
        VStack(spacing: 0) {
            SidebarSearchField(text: $query, prompt: tr("Search"))
                .frame(height: 28)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ScrollViewReader { proxy in
                List(selection: Binding(get: { Optional(nav.route) }, set: { if let r = $0 { nav.go(r) } })) {
                    Section {
                        ForEach(top, id: \.self) { r in
                            row(r, count: r == .permissions ? missing : 0)
                        }
                    }
                    if !modules.isEmpty {
                        Section {
                            ForEach(modules, id: \.self) { row(.module($0)) }
                        } header: {
                            Text(verbatim: tr("Modules"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SettingsStyle.secondary)
                        }
                    }
                    if about {
                        Section { row(.about) }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .overlay {
                    if top.isEmpty, modules.isEmpty, !about {
                        Text(verbatim: tr("No results"))
                            .font(SettingsStyle.font(.m))
                            .foregroundStyle(SettingsStyle.secondary)
                    }
                }
                // Opened on a page far down the list (About, a module from the command bar): show its
                // row. Rows not drawn yet have estimated heights, so the first scroll can stop short;
                // the second, once they are drawn, lands.
                .task {
                    let route = nav.route
                    proxy.scrollTo(route, anchor: .center)
                    try? await Delay.sleep(for: .milliseconds(30))
                    proxy.scrollTo(route, anchor: .center)
                }
            }
        }
        .id(settings.language)
    }

    /// `count`: the permissions still to allow, in an orange badge.
    private func row(_ r: SettingsRoute, count: Int = 0) -> some View {
        let off: Bool = if case .module(let id) = r { !context.settings.isEnabled(id) } else { false }
        return Label {
            HStack(spacing: 6) {
                Text(verbatim: SettingsSidebar.title(r))
                    .foregroundStyle(off ? SettingsStyle.secondary : SettingsStyle.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(SettingsStyle.waiting))
                        .accessibilityLabel(L10n.tr("%d to allow", count))
                }
            }
        } icon: {
            SettingsIcon(symbol: SettingsSidebar.symbol(r), tint: SettingsSidebar.tint(r), size: 20, dimmed: off)
        }
        .tag(r)
        .id(r)
        .help(summary(r))
    }

    /// The row's tooltip: what the page holds right now.
    private func summary(_ r: SettingsRoute) -> String {
        switch r {
        case .general: SettingsCatalog.generalSummary(context.settings)
        case .home: SettingsCatalog.homeSummary(context.settings)
        case .permissions:
            PermissionRows.missing(context) == 0 ? tr("All set") : L10n.tr("%d to allow", PermissionRows.missing(context))
        case .module(let id):
            context.settings.isEnabled(id) ? [tr(SettingsCatalog.purpose(id)), SettingsCatalog.summary(id, context)]
                .filter { !$0.isEmpty }.joined(separator: " · ") : tr("Off")
        case .about: L10n.tr("Version %@", AboutInfo.version)
        }
    }
}

/// The system search field (SwiftUI's own needs a NavigationSplitView).
private struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
        context.coordinator.text = $text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

// MARK: - Detail

/// The selected page, in a centred column, scrolled from the top on every page change.
struct SettingsDetailView: View {
    let context: SurfaceContext
    let crashes: CrashLog
    let close: () -> Void

    var body: some View {
        let nav = context.settings.navigation
        let route = nav.route
        ScrollView {
            page(route, welcome: nav.welcome)
                .frame(maxWidth: 640, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .id(PageID(route: route, language: context.settings.language))
        .environment(\.settingsChrome, .window)
        .onAppear {
            // Opening Settings is a cheap moment to notice a grant made in System Settings.
            context.settings.permissions.refresh()
            context.launchAtLogin.refresh()
        }
    }

    @ViewBuilder private func page(_ route: SettingsRoute, welcome: Bool) -> some View {
        switch route {
        case .general: GeneralSection(context: context)
        case .home: HomeSection(context: context)
        case .permissions: PermissionsSection(context: context, welcome: welcome, done: close)
        case .module(let id): ModuleSection(context: context, id: id)
        case .about: AboutSection(context: context, crashes: crashes)
        }
    }

    private struct PageID: Hashable {
        let route: SettingsRoute
        let language: AppLanguage
    }
}
