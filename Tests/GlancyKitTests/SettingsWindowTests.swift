import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GlancyKit

// The Settings window (W10-SET): the sidebar's pages (generic over ModuleID), page resolution and
// search, one window at a time, released on close, the ⌘, menu, the module switch, the About
// page's crash summaries, the window's segmented-or-menu choice.

@MainActor
private func context(_ modules: [any GlancyModule] = []) -> (SurfaceContext, () -> Void) {
    let suite = "ai.glancy.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    let settings = AppSettings(defaults: d)
    let ctx = SurfaceContext(hub: ActivityHub(), settings: settings, launchAtLogin: LaunchAtLogin(), modules: modules)
    return (ctx, { d.removePersistentDomain(forName: suite) })
}

@MainActor @Suite("Settings window", .serialized)
struct SettingsWindowTests {
    @Test func sidebarListsEveryRegisteredModule() {
        let all = Set(ModuleID.allCases)
        let routes = SettingsSidebar.routes(registered: all)
        #expect(Array(routes.prefix(3)) == [.general, .home, .permissions])
        #expect(routes.last == .about)
        // Every module (and any added later) gets its row, with a name and a symbol.
        let modules = routes.compactMap { r -> ModuleID? in if case .module(let id) = r { id } else { nil } }
        #expect(Set(modules) == all && modules.count == ModuleID.allCases.count)
        for r in routes {
            #expect(!SettingsSidebar.title(r).isEmpty)
            #expect(NSImage(systemSymbolName: SettingsSidebar.symbol(r), accessibilityDescription: nil) != nil, "\(r)")
        }
        // In the panel's tab order; unregistered modules are left out.
        #expect(SettingsSidebar.modules(registered: all) == ModuleID.allCases.enumerated()
            .sorted { (SurfaceContext.order($0.element), $0.offset) < (SurfaceContext.order($1.element), $1.offset) }.map(\.element))
        #expect(SettingsSidebar.routes(registered: [.media]) == [.general, .home, .permissions, .module(.media), .about])
    }

    @Test func pagesResolveToWhatTheSidebarShows() {
        #expect(SettingsSidebar.resolve(nil, registered: []) == .general)
        #expect(SettingsSidebar.resolve(.module(.media), registered: []) == .general)
        #expect(SettingsSidebar.resolve(.module(.media), registered: [.media]) == .module(.media))
        #expect(SettingsSidebar.resolve(.about, registered: []) == .about)
    }

    @Test func searchMatchesPagesAndTheirRows() {
        L10n.apply(.en)
        for r in SettingsSidebar.routes(registered: Set(ModuleID.allCases)) {
            #expect(SettingsSidebar.matches(r, query: ""))
            #expect(SettingsSidebar.matches(r, query: "  "))
        }
        #expect(SettingsSidebar.matches(.general, query: "launch"))           // a row's name
        #expect(SettingsSidebar.matches(.module(.media), query: "LYRICS"))    // any case
        #expect(SettingsSidebar.matches(.module(.agents), query: "codex"))
        #expect(SettingsSidebar.matches(.about, query: "crash"))
        #expect(!SettingsSidebar.matches(.general, query: "pomodoro"))
        #expect(SettingsSidebar.matches(.module(.timer), query: "pomodoro"))
        #expect(!SettingsSidebar.routes(registered: Set(ModuleID.allCases)).contains { SettingsSidebar.matches($0, query: "zzqx") })
    }

    @Test func oneWindowBroughtForwardThenReleased() async throws {
        let (ctx, clean) = context([MediaModule()])
        defer { clean() }
        let first = SettingsWindowController.show(.module(.media), context: ctx, mode: .offscreen)
        #expect(ctx.settings.navigation.route == .module(.media))
        #expect(!first.window.isVisible)                    // never ordered in off-screen
        let again = SettingsWindowController.show(.about, context: ctx, mode: .offscreen)
        #expect(again === first && SettingsWindowController.current === first)
        #expect(ctx.settings.navigation.route == .about)
        // nil keeps the page; a module that isn't registered falls back to General.
        SettingsWindowController.show(nil, context: ctx, mode: .offscreen)
        #expect(ctx.settings.navigation.route == .about)
        SettingsWindowController.show(.module(.clipboard), context: ctx, mode: .offscreen)
        #expect(ctx.settings.navigation.route == .general)

        weak var split: NSViewController?
        weak var page: NSViewController?
        autoreleasepool {
            split = first.window.contentViewController
            page = (split as? NSSplitViewController)?.splitViewItems.last?.viewController
        }
        #expect(split != nil && page != nil)
        first.close()
        #expect(first.isClosed && SettingsWindowController.current == nil)
        #expect(first.window.contentViewController == nil && first.window.delegate == nil)
        for _ in 0..<20 where split != nil || page != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(split == nil && page == nil)                // the hosting controllers are gone
        // Opening again builds a new window.
        let next = SettingsWindowController.show(.general, context: ctx, mode: .offscreen)
        #expect(next !== first)
        next.close()
    }

    @Test func closedWindowIsFreed() async throws {
        let (ctx, clean) = context([MediaModule()])
        defer { clean() }
        weak var controller: SettingsWindowController?
        weak var window: NSWindow?
        autoreleasepool {
            let c = SettingsWindowController.show(.module(.media), context: ctx, mode: .offscreen)
            controller = c
            window = c.window
            ctx.settings.navigation.go(.about)
            c.close()
        }
        for _ in 0..<50 where controller != nil || window != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller == nil && window == nil)        // nothing keeps the closed window
    }

    @Test func welcomeOpensOnPermissionsAndEndsOnClose() {
        let (ctx, clean) = context()
        defer { clean() }
        let w = SettingsWindowController.show(nil, context: ctx, welcome: true, mode: .offscreen)
        #expect(ctx.settings.navigation.route == .permissions && ctx.settings.navigation.welcome)
        w.close()
        #expect(!ctx.settings.navigation.welcome)
    }

    @Test func titleFollowsThePage() async throws {
        let (ctx, clean) = context([MediaModule()])
        defer { clean() }
        L10n.apply(.en)
        let w = SettingsWindowController.show(.general, context: ctx, mode: .offscreen)
        defer { w.close() }
        #expect(w.window.title == "General")
        ctx.settings.navigation.go(.module(.media))
        for _ in 0..<20 where w.window.title != "Media" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(w.window.title == "Media")
    }

    @Test func commandCommaOpensSettings() {
        var opened = 0
        let target = SettingsMenu.MenuTarget { opened += 1 }
        let menu = SettingsMenu.make(target: target)
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        #expect(items.count == 1)
        guard let item = items.first, let action = item.action else { Issue.record("no Settings item"); return }
        #expect(item.keyEquivalent == "," && item.keyEquivalentModifierMask == .command)
        // No ⌘Q: the panel takes the keyboard without activating Glancy.
        #expect(!items.contains { $0.keyEquivalent == "q" })
        NSApp.sendAction(action, to: item.target, from: item)
        #expect(opened == 1)
    }

    @Test func moduleSwitchGoesThroughTheApp() {
        let (ctx, clean) = context([MediaModule()])
        defer { clean() }
        var calls: [(ModuleID, Bool)] = []
        ctx.setModuleEnabled = { id, on in calls.append((id, on)); ctx.settings.setEnabled(id, on) }
        let binding = ModuleSection.enabled(.media, ctx)
        #expect(binding.wrappedValue == ctx.settings.isEnabled(.media))
        binding.wrappedValue = false
        #expect(calls.count == 1 && calls[0].0 == .media && calls[0].1 == false)
        #expect(!ctx.settings.isEnabled(.media) && !binding.wrappedValue)
        binding.wrappedValue = true
        #expect(ctx.settings.isEnabled(.media))
    }

    @Test func crashSummariesReadAsRows() {
        let url = URL(fileURLWithPath: "/tmp/2026-10-06-001206.txt")
        let e = CrashLog.entry("Glancy 0.4.0 (4000) crashed 2026-10-06 00:12:06.00 +0200\nmacOS 26.0\nEXC_BREAKPOINT (SIGTRAP)\n", url: url)
        #expect(e.date == "2026-10-06 00:12:06")
        #expect(e.exception == "Glancy 0.4.0 (4000) · EXC_BREAKPOINT (SIGTRAP)")
        let bare = CrashLog.entry("", url: url)
        #expect(bare.date == "2026-10-06-001206" && bare.exception.isEmpty)
    }

    @Test func crashSummariesNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-crash-\(UUID().uuidString)")
        let reports = dir.appendingPathComponent("reports"), out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, ts) in [("2026-09-28-090314", "2026-09-28 09:03:14.00 +0200"), ("2026-10-06-001206", "2026-10-06 00:12:06.00 +0200")] {
            try "Glancy 0.4.0 (4000) crashed \(ts)\nmacOS\nEXC_CRASH\n".write(to: out.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
        let entries = CrashLog.read(reports: reports, out: out)
        #expect(entries.map(\.date) == ["2026-10-06 00:12:06", "2026-09-28 09:03:14"])
    }

    @Test func fewShortChoicesAreSegmented() {
        #expect(NotchSegments<Int>.prefersSegments(["Click", "Hover"]))
        #expect(NotchSegments<Int>.prefersSegments(["System", "English", "Italiano"]))
        #expect(!NotchSegments<Int>.prefersSegments(["15 min", "30 min", "1 h", "2 h"]))
        #expect(!NotchSegments<Int>.prefersSegments(["Solo quando serve", "Sempre", "Mai più"]))
    }
}
