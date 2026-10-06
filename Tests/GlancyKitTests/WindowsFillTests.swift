// "Fill empty space": one chosen window into the largest area no other window covers. On the
// main surface it is the last thumbnail once exactly one window is the subject; ⌃⌥F and the
// command bar do it for the front window. Synthetic two-display Mac: commits are recorded,
// nothing real moves.
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

@MainActor
private func open(_ b: SampleWindowsBackend) async -> WindowsModel {
    let model = WindowsModel(backend: b)
    model.outcomeDuration = .milliseconds(1)
    model.closeDelay = .milliseconds(1)
    model.pointer = { CGPoint(x: 756, y: 960) }
    model.open(keyboard: false)
    await model.pending?.value
    return model
}

/// The built-in with Safari moved up to the ultrawide: the right of the built-in is free.
@MainActor
private func roomyDesk() -> SampleWindowsBackend {
    let b = SampleWindowsBackend()
    if let i = b.windows.firstIndex(where: { $0.id == 12 }) { b.windows[i].frame = CGRect(x: 1200, y: 1300, width: 900, height: 740) }
    return b
}

@Suite("Windows: fill the empty space")
@MainActor
struct WindowsFillTests {
    @Test func offeredOnlyForOneWindowWithOthersBesideIt() async {
        let b = roomyDesk()
        let model = await open(b)
        #expect(!model.layoutOptions.contains { $0.shape.kind == .fill })     // nothing picked: three windows
        model.click(14, .plain)
        #expect(model.layoutOptions.last?.id == WindowsAutoLayout.fillOption.id)
        model.click(13, .plain)
        #expect(!model.layoutOptions.contains { $0.shape.kind == .fill })     // two picked
        // Alone on its display: filling would only be "full screen".
        let alone = SampleWindowsBackend(windows: SampleWindowsBackend.standardWindows.filter { $0.id == 14 || $0.id > 20 })
        let m2 = await open(alone)
        #expect(m2.layoutWindows.count == 1)
        #expect(!m2.layoutOptions.contains { $0.shape.kind == .fill })
    }

    @Test func previewsWhereNoOtherWindowIsAndApplyCommitsThatAndRaises() async throws {
        let b = roomyDesk()
        let model = await open(b)
        var shown: [ArrangePlan?] = []
        model.onPreview = { p, _ in shown.append(p) }
        model.click(14, .plain)
        model.hoverLayout(WindowsAutoLayout.fillOption.id)
        let preview = try #require(model.layoutPlan)
        #expect(preview.kind == .fit && preview.moves.map(\.windowID) == [14])
        #expect(shown.last??.moves.first?.to == preview.moves[0].to)            // on the real screen too
        let to = preview.moves[0].to
        let grid = b.grid(for: SampleWindowsBackend.builtIn)
        for id: CGWindowID in [11, 13] {
            let other = b.window(id)!.frame.insetBy(dx: -grid.innerGap + 0.5, dy: -grid.innerGap + 0.5)
            #expect(!other.intersects(to), "clear of \(id) and its gap")
        }
        #expect(SampleWindowsBackend.builtIn.usableFrame.insetBy(dx: grid.outerGap, dy: grid.outerGap).contains(to))
        #expect(b.commits.isEmpty)                                               // hovering previews only
        model.chooseLayout(WindowsAutoLayout.fillOption.id)
        model.hoverLayout(nil)
        model.applyLayout()
        await model.pending?.value
        #expect(b.commits == [preview])
        #expect(b.raises == [[14]])
        #expect(b.window(14)?.frame == to)
        #expect(model.canUndo)
    }

    @Test func noRoomSaysSoAndMovesNothing() async {
        let b = SampleWindowsBackend()
        if let i = b.windows.firstIndex(where: { $0.id == 12 }) { b.windows[i].frame = SampleWindowsBackend.builtIn.usableFrame }
        let model = await open(b)
        model.click(14, .plain)
        model.chooseLayout(WindowsAutoLayout.fillOption.id)
        #expect(model.fillHasNoRoom)
        #expect(model.layoutPlan == nil)
        model.applyLayout()
        await model.pending?.value
        #expect(b.commits.isEmpty && b.raises.isEmpty)
    }

    @Test func hotkeyFillsTheFrontWindowOrSaysThereIsNoRoom() async {
        let b = roomyDesk()
        b.targetWindowID = 14
        let model = WindowsModel(backend: b)
        #expect(await model.direct(.fit) == nil)                                 // landed exactly: no peek
        #expect(b.commits.last?.kind == .fit && b.commits.last?.moves.first?.windowID == 14)
        let full = SampleWindowsBackend()
        if let i = full.windows.firstIndex(where: { $0.id == 12 }) { full.windows[i].frame = SampleWindowsBackend.builtIn.usableFrame }
        full.targetWindowID = 14
        #expect(await WindowsModel(backend: full).direct(.fit) == WindowsText.t("No empty space on this display"))
        #expect(full.commits.isEmpty)
    }

    @Test func commandBarFillsTheFrontWindow() async {
        let windows = WindowsModule(engine: TilingEngine(configURL: nil), hotkeysURL: nil)
        let b = roomyDesk()
        b.targetWindowID = 14
        windows.useForTests(backend: b) { _, _ in }
        windows.model.pointer = { CGPoint(x: 756, y: 960) }
        #expect(windows.commands().contains { $0.id == "windows.layout.fill" })
        #expect(windows.results(for: "fill").first?.id == "windows.layout.fill")
        #expect(windows.results(for: "riempi").first?.id == "windows.layout.fill")
        #expect(windows.results(for: "maximize").first?.id == "windows.layout.maximize")
        #expect(b.commits.isEmpty)
        let line = await windows.model.fillCommand()
        #expect(line.hasPrefix(WindowsText.t("Fill empty space")))
        #expect(b.commits.last?.kind == .fit)
        #expect(b.raises == [[14]])
    }
}
