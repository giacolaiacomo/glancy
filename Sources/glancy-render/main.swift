import AppKit
import GlancyKit
import SwiftUI

// Renders every surface state to PNG at 2×, off-screen, over a real-looking menu-bar strip, using
// the real modules from Modules.swift plus the demo ones. SPEC §5. Usage:
//   glancy-render [out-dir] [--it] [--demo]
// --demo replaces every module's data with made-up content (DemoData): no real sessions, calendar,
// music, clipboard, shelf, devices or windows. Use it for anything published.

@MainActor
enum Render {
    static let scale: CGFloat = 2
    static let crop = CGSize(width: 900, height: 290)
    /// The menu bar clock: fixed, or the real time with --demo so it agrees with the demo calendar.
    nonisolated(unsafe) static var clock = "Mon 5 Oct  09:41"

    static func run() {
        let args = CommandLine.arguments.dropFirst()
        let out = URL(fileURLWithPath: args.first(where: { !$0.hasPrefix("--") }) ?? "render-out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let geometry = builtInGeometry()
        let suite = "ai.glancy.render"
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.language = args.contains("--it") ? .it : .en
        let launch = LaunchAtLogin()

        // The real modules (plus the demo) started on a live hub; empty hubs for the quiet states.
        // --demo: made-up data only (DemoData), for README and release images.
        let demo = args.contains("--demo")
        let demoRoot = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: demoRoot) }
        let modules = demo ? DemoData.modules(root: demoRoot) : Modules.make(demo: true)
        if demo {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "EEE d MMM  HH:mm"
            clock = f.string(from: .now)
        }
        for m in modules { (m as? DemoModule)?.cyclesPeeks = false }
        func context(_ started: Bool, _ list: [any GlancyModule]? = nil) -> SurfaceContext {
            let hub = ActivityHub()
            if started { for m in modules { m.stop(); m.start(hub: hub) } }
            return SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: list ?? modules)
        }
        let live = context(true)
        let quiet = context(false)
        let media = modules.compactMap { $0 as? DemoModule }.first { $0.id == .media }
        let suffix = settings.language == .it ? "-it" : ""

        func shot(_ name: String, _ ctx: SurfaceContext, dark: Bool = false, geometry: NotchGeometry = geometry,
                  menus: MenuBarClearance? = nil, _ setup: (SurfaceModel) -> Void = { _ in }) {
            let model = SurfaceModel(geometry: geometry)
            model.animates = false
            setup(model)
            let file = out.appendingPathComponent("\(name)\(suffix).png")
            render(model: model, context: ctx, geometry: geometry, dark: dark, menus: menus, to: file)
            let l = model.layout
            print("wrote \(file.lastPathComponent)  state=\(model.state) shape=\(Int(l.size.width))×\(Int(l.size.height)) wings=\(Int(l.wingLeft))/\(Int(l.wingRight))")
        }

        shot("01-idle", quiet)
        shot("01-idle-dark", quiet, dark: true)
        shot("02-activity", live)
        shot("02-activity-dark", live, dark: true)
        // Menus reaching the notch (Chrome on a 14"): no left wing; the right one stops 6 pt short
        // of the first status item (92 pt right of the notch, as measured on this Mac).
        let crowded = MenuBarClearance(left: 8, right: 92, source: .measured)
        shot("02-activity-crowded", live, menus: crowded) { $0.setClearance(crowded) }
        let blocked = MenuBarClearance(left: 8, right: 18, source: .measured)   // both sides full: notch only
        shot("02-activity-blocked", live, menus: blocked) { $0.setClearance(blocked) }
        shot("03-peek", live) { $0.setHovering(true) }
        shot("03-peek-idle", quiet) { $0.setHovering(true) }
        for (n, name) in ["track", "airpods"].enumerated() {
            let ctx = context(true)
            media?.showSamplePeek(n)
            shot("04-peekEvent-\(name)", ctx)
        }
        shot("05-expanded-home", live) { $0.expand(tab: nil) }
        shot("05-expanded-home-empty", context(false, [])) { $0.expand(tab: nil) }
        for (i, tab) in live.tabs.enumerated() {
            shot("06-tab-\(i + 1)-\(tab.module.rawValue)", live) { $0.expand(tab: tab.module) }
        }
        // Windows tab states on a synthetic two-display Mac (no Accessibility needed here).
        if let windows = modules.compactMap({ $0 as? WindowsModule }).first {
            for state in WindowsModule.RenderState.allCases {
                windows.prepareForRender(state)
                shot("09-windows-\(state.rawValue)", live) { $0.expand(tab: .windows) }
            }
        }
        // Notifications (opt-in, off by default): turned on for these shots only, synthetic data.
        if let notes = modules.compactMap({ $0 as? NotificationsModule }).first {
            settings.setEnabled(.notifications, true)
            for state in NotificationsModule.RenderState.allCases {
                notes.prepareForRender(state)
                shot("10-notifications-\(state.rawValue)", live) { $0.expand(tab: .notifications) }
            }
            let ctx = context(true)
            notes.showSamplePeek()
            shot("10-notifications-peek", ctx)
            settings.setEnabled(.notifications, false)
        }
        // Shelf: drop targets while dragging, item actions, screenshot and download drop-downs
        // (sample files in a scratch folder; the real shelf is never saved over).
        if let shelf = modules.compactMap({ $0 as? ShelfModule }).first {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-render-shelf-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            for state in ShelfModule.RenderState.allCases {
                let ctx = context(true)
                shelf.prepareForRender(state, scratch: scratch)
                if state.isPeek {
                    shot("11-shelf-\(state.rawValue)", ctx)
                } else {
                    shot("11-shelf-\(state.rawValue)", ctx) { $0.expand(tab: .shelf) }
                }
            }
            shelf.endRender()
        }
        // Settings: the index, every section, and the first-run welcome. Permission statuses are
        // fixed (a mix of every state) so nothing is asked of macOS.
        let fixed: [PermissionKind: PermissionStatus] = [.calendar: .granted, .accessibility: .notDetermined, .bluetooth: .denied,
                                                         .notifications: .notDetermined, .automation: .notDetermined,
                                                         .fullDiskAccess: .denied]
        settings.permissions.probe = .fixed(fixed)
        settings.permissions.apply(fixed)
        let routes: [(String, SettingsRoute)] = [("index", .index), ("general", .general), ("modules", .modules),
                                                 ("permissions", .permissions)]
            + live.modules.map(\.id).filter { $0 != .notifications }.map { ("module-\($0.rawValue)", .module($0)) }
        for (name, route) in routes {
            settings.navigation.go(route, animated: false)
            shot(name == "index" ? "07-settings" : "07-settings-\(name)", live) { $0.expand(tab: nil); $0.toggleSettings() }
        }
        settings.navigation.showWelcome()
        shot("07-settings-welcome", live) { $0.expand(tab: nil); $0.toggleSettings() }
        settings.navigation.go(.index, animated: false)
        // The opt-in pill on a display without a notch (menu bar 24 pt).
        let external = ScreenInfo(uuid: "external", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 958), safeTop: 0,
                                  auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 2)
        let pill = NotchGeometry.pill(for: external, menuBarHeight: 24)
        shot("08-pill-idle", quiet, geometry: pill)
        shot("08-pill-activity", context(true), geometry: pill)
        for m in modules { m.stop() }
    }

    /// This Mac's notched display if there is one, otherwise a 14" MacBook Pro.
    static func builtInGeometry() -> NotchGeometry {
        for s in NSScreen.screens {
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, s.safeAreaInsets.top > 0 {
                let dx = -s.frame.minX, dy = -s.frame.minY
                let info = ScreenInfo(uuid: "builtin", frame: s.frame.offsetBy(dx: dx, dy: dy),
                                      visibleFrame: s.visibleFrame.offsetBy(dx: dx, dy: dy), safeTop: s.safeAreaInsets.top,
                                      auxLeft: l.offsetBy(dx: dx, dy: dy), auxRight: r.offsetBy(dx: dx, dy: dy),
                                      isBuiltin: true, scale: 2)
                if let g = NotchGeometry.notch(for: info) { return g }
            }
        }
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let info = ScreenInfo(uuid: "builtin", frame: frame, visibleFrame: frame, safeTop: 32,
                              auxLeft: CGRect(x: 0, y: 950, width: 665, height: 32),
                              auxRight: CGRect(x: 850, y: 950, width: 662, height: 32), isBuiltin: true, scale: 2)
        return NotchGeometry.notch(for: info)!
    }

    static func render(model: SurfaceModel, context: SurfaceContext, geometry g: NotchGeometry, dark: Bool,
                       menus: MenuBarClearance? = nil, to url: URL) {
        let cropX = (g.notchRect.midX - crop.width / 2).rounded()
        let scene = Scene(model: model, context: context, geometry: g, cropX: cropX, dark: dark, menus: menus)
            .frame(width: crop.width, height: crop.height)
        let host = NSHostingView(rootView: scene)
        host.frame = CGRect(origin: .zero, size: crop)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: crop.width, height: crop.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Let measurements (wings, peek content) land in the model and the layout follow.
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        }
        host.layoutSubtreeIfNeeded()
        host.display()

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(crop.width * scale), pixelsHigh: Int(crop.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = crop
        // Inside the panel: the AppKit capture, which renders every control (scroll views, lists,
        // switches). Outside it: SwiftUI's ImageRenderer, which also draws the panel's shadow.
        host.cacheDisplay(in: host.bounds, to: rep)
        let layout = model.layout
        let frame = layout.windowFrame(in: g)
        let shapeRect = CGRect(x: frame.minX - cropX + (frame.width - layout.size.width) / 2,
                               y: crop.height - layout.size.height,
                               width: layout.size.width, height: layout.size.height)
        // The hardware notch sits physically above every pixel: draw it last, so anything the
        // panel puts under it shows up as hidden in the render, exactly as on the real screen.
        let hardware = g.kind == .notch
            ? CGRect(x: g.notchRect.minX - cropX, y: crop.height - g.notchRect.height,
                     width: g.notchRect.width, height: g.notchRect.height) : nil
        let output = composite(inside: rep, outside: ImageRenderer(content: scene).withScale(scale).cgImage,
                               shape: NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius),
                               in: shapeRect, hardwareNotch: hardware)
        try? output.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
        window.close()
    }
}

/// `outside` everywhere, then `inside` clipped to the panel shape (y-up crop coordinates).
@MainActor
private func composite(inside: NSBitmapImageRep, outside: CGImage?, shape: NotchShape, in rect: CGRect,
                       hardwareNotch: CGRect? = nil) -> NSBitmapImageRep {
    guard let outside, let insideCG = inside.cgImage else { return inside }
    let w = inside.pixelsWide, h = inside.pixelsHigh
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = inside.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let ctx = NSGraphicsContext.current!.cgContext
    // The context is in points (the rep's size), already scaled to pixels.
    let full = CGRect(origin: .zero, size: inside.size)
    ctx.draw(outside, in: full)
    // NotchShape is drawn y-down; flip it into the y-up context.
    var t = CGAffineTransform(translationX: rect.minX, y: rect.maxY).scaledBy(x: 1, y: -1)
    let path = shape.path(in: CGRect(origin: .zero, size: rect.size)).cgPath
    if let clip = path.copy(using: &t) {
        ctx.addPath(clip)
        ctx.clip()
        ctx.draw(insideCG, in: full)
    }
    if let n = hardwareNotch {
        ctx.resetClip()
        var tn = CGAffineTransform(translationX: n.minX, y: n.maxY).scaledBy(x: 1, y: -1)
        if let p = NotchShape(topRadius: 6, bottomRadius: 10).path(in: CGRect(origin: .zero, size: n.size)).cgPath.copy(using: &tn) {
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return out
}

@MainActor private extension ImageRenderer {
    func withScale(_ s: CGFloat) -> ImageRenderer { scale = s; return self }
}

/// The surface over a strip of desktop: wallpaper, menu bar (menus left, status items right), and
/// the hardware notch drawn underneath, so the blend can be judged.
private struct Scene: View {
    let model: SurfaceModel
    let context: SurfaceContext
    let geometry: NotchGeometry
    let cropX: CGFloat
    let dark: Bool
    let menus: MenuBarClearance?

    var body: some View {
        let screen = geometry.screenFrame
        // The surface view is laid out centred on the notch, like the app's hosting view.
        let frame = SurfaceLayout.hostFrame(in: geometry, window: model.layout.windowFrame(in: geometry))
        let notch = geometry.notchRect
        ZStack(alignment: .topLeading) {
            Wallpaper(dark: dark)
            MenuBar(width: screen.width, height: notch.height, dark: dark, menus: menus,
                    notch: notch.offsetBy(dx: -screen.minX, dy: 0))
                .offset(x: -cropX)
            // The hardware notch the panel must disappear into.
            if geometry.kind == .notch {
                NotchShape(topRadius: 6, bottomRadius: 10)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
                    .offset(x: notch.minX - cropX)
            }
            SurfaceView(model: model, context: context)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX - cropX)
        }
        .frame(width: Render.crop.width, height: Render.crop.height, alignment: .topLeading)
        .clipped()
    }
}

private struct Wallpaper: View {
    let dark: Bool
    var body: some View {
        if dark {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.20, green: 0.14, blue: 0.28),
                                    Color(red: 0.08, green: 0.08, blue: 0.12)], startPoint: .top, endPoint: .bottom)
        } else {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.80, green: 0.86, blue: 0.96), Color(red: 0.86, green: 0.80, blue: 0.93),
                                        Color(red: 0.96, green: 0.84, blue: 0.80)], startPoint: .top, endPoint: .bottom)
                // A window below the menu bar, for scale.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
                    .frame(width: 560, height: 260)
                    .offset(x: 40, y: 96)
            }
        }
    }
}

private struct MenuBar: View {
    let width: CGFloat
    let height: CGFloat
    let dark: Bool
    /// When set, the menus end `left` before the notch and the status items start `right` after it.
    var menus: MenuBarClearance? = nil
    var notch: CGRect = .zero

    var body: some View {
        if let menus { crowded(menus) } else { standard }
    }

    /// Chrome's menus packed up to the notch, the status items at the measured distance.
    private func crowded(_ c: MenuBarClearance) -> some View {
        let ink = dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 19) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
                Text("Google Chrome").fontWeight(.bold)
                ForEach(["File", "Edit", "View", "History", "Bookmarks", "Profiles", "Tab", "Window", "Help"], id: \.self) { Text($0) }
            }
            .fixedSize()
            .frame(width: notch.minX - c.left, height: height, alignment: .trailing)
            HStack(spacing: 17) {
                Image(systemName: "shippingbox")
                Image(systemName: "chart.bar")
                Image(systemName: "rectangle.3.group")
                Image(systemName: "shield")
                Image(systemName: "battery.75percent")
                Image(systemName: "wifi")
                Text(Render.clock)
            }
            .fixedSize()
            .frame(height: height)
            .offset(x: notch.maxX + c.right)
        }
        .font(.system(size: 13))
        .foregroundStyle(ink)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(dark ? Color.black.opacity(0.18) : Color.white.opacity(0.18))
    }

    private var standard: some View {
        let ink = dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
        return HStack(spacing: 0) {
            HStack(spacing: 19) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
                Text("Code").fontWeight(.bold)
                ForEach(["File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Window", "Help"], id: \.self) { Text($0) }
            }
            .padding(.leading, 20)
            Spacer()
            HStack(spacing: 17) {
                Image(systemName: "record.circle")
                Image(systemName: "cloud")
                Image(systemName: "rectangle.3.group")
                Image(systemName: "battery.75percent")
                Image(systemName: "wifi")
                Image(systemName: "magnifyingglass")
                Image(systemName: "switch.2")
                Text(Render.clock)
            }
            .padding(.trailing, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(ink)
        .frame(width: width, height: height)
        .background(dark ? Color.black.opacity(0.18) : Color.white.opacity(0.18))
    }
}

Render.run()
