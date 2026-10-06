import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GlancyKit

/// A scratch folder per test (never the user's Desktop or Downloads), removed at the end.
private struct Temp {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-shelfplus-\(UUID().uuidString)", isDirectory: true)
    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func dir(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ name: String, in folder: URL, _ text: String = "hello") -> URL {
        let url = folder.appendingPathComponent(name)
        try? Data(text.utf8).write(to: url)
        return url
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// Waits (briefly) for a condition that an event will make true.
@MainActor
private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func makeImage(_ url: URL, width: Int, height: Int, type: UTType) throws {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

// MARK: - Rules

@Suite struct ShelfFolderRulesTests {
    @Test func screenshotNamesInEnglishAndItalian() {
        #expect(ShelfFolderRules.isScreenshot("Screenshot 2026-10-05 at 09.41.22.png"))
        #expect(ShelfFolderRules.isScreenshot("Screen Shot 2019-05-10 at 10.25.33.png"))
        #expect(ShelfFolderRules.isScreenshot("Istantanea 2026-10-05 alle 09.41.22.png"))
        #expect(ShelfFolderRules.isScreenshot("Schermata 2019-05-10 alle 10.25.33.jpg"))
        #expect(ShelfFolderRules.isScreenshot("Screenshot 2026-10-05 at 09.41.22 (2).png"))
        // Hidden temp file macOS writes first, a recording, an unrelated file, a lookalike.
        #expect(!ShelfFolderRules.isScreenshot(".Screenshot 2026-10-05 at 09.41.22.png"))
        #expect(!ShelfFolderRules.isScreenshot("Screen Recording 2026-10-05 at 09.41.22.mov"))
        #expect(!ShelfFolderRules.isScreenshot("Screenshot 2026-10-05 at 09.41.22.mov"))
        #expect(!ShelfFolderRules.isScreenshot("holiday.png"))
        #expect(!ShelfFolderRules.isScreenshot("Screenshots of the app.png"))
        // A custom prefix (defaults write com.apple.screencapture name "Cattura").
        #expect(ShelfFolderRules.isScreenshot("Cattura 2026-10-05 alle 09.41.22.png", customPrefix: "Cattura"))
        #expect(!ShelfFolderRules.isScreenshot("Cattura 2026-10-05 alle 09.41.22.png"))
    }

    @Test func partialDownloadsAreNoise() {
        for name in ["report.pdf.crdownload", "Unconfirmed 123.crdownload", "report.pdf.download", "report.pdf.part",
                     "movie.mp4.partial", "x.zip.opdownload", ".DS_Store", ".com.google.Chrome.abc"] {
            #expect(!ShelfFolderRules.isDownload(name), "\(name)")
        }
        #expect(ShelfFolderRules.isDownload("report.pdf"))
        #expect(ShelfFolderRules.isDownload("Invoice (1).pdf"))
        #expect(ShelfFolderRules.hasPartialSibling("b.pdf", among: ["b.pdf", "b.pdf.part"]))
        #expect(!ShelfFolderRules.hasPartialSibling("b.pdf", among: ["b.pdf", "c.pdf.part"]))
    }

    @Test func screenshotFolderFromPreferences() throws {
        let t = Temp(); defer { t.cleanUp() }
        let home = t.dir("home")
        let shots = t.dir("home/Pictures/Shots")
        let suite = "ai.glancy.tests.screencapture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ShelfFolderRules.screenshotFolder(defaults: defaults, home: home).lastPathComponent == "Desktop")
        defaults.set("~/Pictures/Shots", forKey: "location")
        #expect(ShelfFolderRules.screenshotFolder(defaults: defaults, home: home).path == shots.path)
        defaults.set("/nowhere/at/all", forKey: "location")
        #expect(ShelfFolderRules.screenshotFolder(defaults: defaults, home: home).lastPathComponent == "Desktop")
    }
}

// MARK: - Watcher (temp folders only)

@MainActor
@Suite(.serialized) struct ShelfFolderWatcherTests {
    private func watcher(_ folder: URL, accepts: @escaping (String) -> Bool = ShelfFolderRules.isDownload)
        -> (ShelfFolderWatcher, Box) {
        let w = ShelfFolderWatcher(folder: folder, settle: .milliseconds(150), accepts: accepts)
        let box = Box()
        w.onFiles = { box.batches.append($0.map(\.lastPathComponent)) }
        return (w, box)
    }

    @MainActor final class Box { var batches: [[String]] = [] }

    @Test func renamedDownloadIsReportedOnceAndOldFilesNever() async throws {
        let t = Temp(); defer { t.cleanUp() }
        let folder = t.dir("Downloads")
        t.write("old.pdf", in: folder)
        let (w, box) = watcher(folder)
        #expect(await w.start() == .watching)
        defer { w.stop() }
        // Chrome: "<name>.crdownload" while writing, renamed when done.
        let partial = t.write("report.pdf.crdownload", in: folder, String(repeating: "x", count: 4096))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(box.batches.isEmpty)
        try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent("report.pdf"))
        #expect(await eventually { box.batches == [["report.pdf"]] })
        // Touching the folder again doesn't report it twice.
        t.write(".DS_Store", in: folder)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(box.batches == [["report.pdf"]])
    }

    @Test func firefoxPlaceholderWaitsForThePartFile() async throws {
        let t = Temp(); defer { t.cleanUp() }
        let folder = t.dir("Downloads")
        let (w, box) = watcher(folder)
        #expect(await w.start() == .watching)
        defer { w.stop() }
        // Firefox: an empty final name at once, the data in "<name>.part".
        t.write("b.pdf", in: folder, "")
        let part = t.write("b.pdf.part", in: folder, "data")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(box.batches.isEmpty)
        #expect(w.pendingNames == ["b.pdf"])
        _ = try FileManager.default.replaceItemAt(folder.appendingPathComponent("b.pdf"), withItemAt: part)
        #expect(await eventually { box.batches == [["b.pdf"]] })
    }

    @Test func burstIsOneReportAndShortLivedFilesAreIgnored() async throws {
        let t = Temp(); defer { t.cleanUp() }
        let folder = t.dir("Downloads")
        let (w, box) = watcher(folder)
        #expect(await w.start() == .watching)
        defer { w.stop() }
        for n in ["a.txt", "b.txt", "c.txt"] { t.write(n, in: folder) }
        let gone = t.write("temp.bin", in: folder)
        try FileManager.default.removeItem(at: gone)
        #expect(await eventually { !box.batches.isEmpty })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(box.batches == [["a.txt", "b.txt", "c.txt"]])
    }

    @Test func screenshotsOnlyAfterTheHiddenFileIsRenamed() async throws {
        let t = Temp(); defer { t.cleanUp() }
        let folder = t.dir("Desktop")
        let (w, box) = watcher(folder) { ShelfFolderRules.isScreenshot($0) }
        #expect(await w.start() == .watching)
        defer { w.stop() }
        let name = "Screenshot 2026-10-05 at 09.41.22.png"
        let hidden = folder.appendingPathComponent("." + name)
        try makeImage(hidden, width: 40, height: 20, type: .png)
        t.write("notes.txt", in: folder)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(box.batches.isEmpty)
        try FileManager.default.moveItem(at: hidden, to: folder.appendingPathComponent(name))
        #expect(await eventually { box.batches == [[name]] })
    }

    @Test func missingFolderIsReported() async {
        let w = ShelfFolderWatcher(folder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), accepts: { _ in true })
        #expect(await w.start() == .missing)
        w.stop()
    }

    @Test func permissionErrorsAreRecognised() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(ShelfFolderWatcher.isPermission(denied))
        #expect(!ShelfFolderWatcher.isPermission(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
    }
}

// MARK: - Zip and convert

@Suite struct ShelfFileOpsTests {
    @Test func zipOneAndManyWithUniqueNames() throws {
        let t = Temp(); defer { t.cleanUp() }
        let src = t.dir("src")
        let a = t.write("a.txt", in: src, "alpha"), b = t.write("b.txt", in: src, "beta")
        let single = try ShelfFileOps.zip([a], into: src)
        #expect(single.lastPathComponent == "a.txt.zip")
        let many = try ShelfFileOps.zip([a, b], into: src)
        #expect(many.lastPathComponent == "Archive.zip")
        let again = try ShelfFileOps.zip([a, b], into: src)
        #expect(again.lastPathComponent == "Archive 2.zip")
        // The archive opens to the files themselves.
        let out = t.dir("out")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", many.path, out.path]
        try p.run(); p.waitUntilExit()
        #expect(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8) == "alpha")
        #expect(try String(contentsOf: out.appendingPathComponent("b.txt"), encoding: .utf8) == "beta")
        // Originals untouched.
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    @Test func convertPNGAndHEICToJPEGAndHalveSize() throws {
        let t = Temp(); defer { t.cleanUp() }
        let src = t.dir("src")
        let png = src.appendingPathComponent("shot.png")
        try makeImage(png, width: 200, height: 100, type: .png)
        let jpg = try ShelfFileOps.convert(png, .jpeg, into: src)
        #expect(jpg.lastPathComponent == "shot.jpg")
        #expect(ShelfFileOps.pixelSize(jpg) == CGSize(width: 200, height: 100))
        #expect((CGImageSourceCreateWithURL(jpg as CFURL, nil).flatMap(CGImageSourceGetType) as String?) == UTType.jpeg.identifier)
        let half = try ShelfFileOps.convert(png, .half, into: src)
        #expect(half.lastPathComponent == "shot 50%.png")
        #expect(ShelfFileOps.pixelSize(half) == CGSize(width: 100, height: 50))

        let heic = src.appendingPathComponent("photo.heic")
        try makeImage(heic, width: 64, height: 48, type: .heic)
        let fromHeic = try ShelfFileOps.convert(heic, .jpeg, into: src)
        #expect(fromHeic.lastPathComponent == "photo.jpg")
        #expect(ShelfFileOps.pixelSize(fromHeic) == CGSize(width: 64, height: 48))
        // A second conversion never overwrites the first.
        #expect(try ShelfFileOps.convert(png, .jpeg, into: src).lastPathComponent == "shot 2.jpg")
        #expect(ShelfFileOps.isImage(png) && ShelfFileOps.isImage(heic))
        #expect(!ShelfFileOps.isImage(src.appendingPathComponent("doc.pdf")))
        #expect(throws: ShelfFileOps.OpError.self) { try ShelfFileOps.convert(t.write("x.png", in: src, "not an image"), .jpeg, into: src) }
    }

    @Test func outputGoesBesideOriginalsButNotIntoStaging() {
        let t = Temp(); defer { t.cleanUp() }
        let src = t.dir("src"), staging = t.dir("store/shelf-files")
        let file = t.write("a.txt", in: src)
        #expect(ShelfFileOps.outputFolder(beside: [file], staging: staging)?.path == src.standardizedFileURL.path)
        let staged = t.write("b.txt", in: t.dir("store/shelf-files/\(UUID().uuidString)"))
        #expect(ShelfFileOps.outputFolder(beside: [staged], staging: staging) == nil)
        #expect(ShelfFileOps.outputFolder(beside: [URL(fileURLWithPath: "/System/Library/a.txt")], staging: staging) == nil)
    }
}

// MARK: - Drop targets

@Suite struct ShelfDropTargetTests {
    let frames: [ShelfDropAction: CGRect] = [
        .shelf: CGRect(x: 0, y: 0, width: 260, height: 140),
        .airDrop: CGRect(x: 268, y: 0, width: 112, height: 140),
        .share: CGRect(x: 388, y: 0, width: 112, height: 140),
        .zip: CGRect(x: 508, y: 0, width: 112, height: 140),
    ]

    @Test func hitTesting() {
        #expect(ShelfDropAction.hit(CGPoint(x: 10, y: 10), frames: frames) == .shelf)
        #expect(ShelfDropAction.hit(CGPoint(x: 300, y: 70), frames: frames) == .airDrop)
        #expect(ShelfDropAction.hit(CGPoint(x: 499, y: 139), frames: frames) == .share)
        #expect(ShelfDropAction.hit(CGPoint(x: 600, y: 1), frames: frames) == .zip)
        // The gap between tiles and outside the strip belong to nobody.
        #expect(ShelfDropAction.hit(CGPoint(x: 264, y: 70), frames: frames) == nil)
        #expect(ShelfDropAction.hit(CGPoint(x: 300, y: 150), frames: frames) == nil)
        #expect(ShelfDropAction.hit(CGPoint(x: 300, y: 70), frames: [:]) == nil)
    }

    @Test func dropFallsBackToTheShelf() {
        #expect(ShelfDropAction.resolve(nil, targetsShown: true) == .shelf)
        #expect(ShelfDropAction.resolve(.zip, targetsShown: true) == .zip)
        #expect(ShelfDropAction.resolve(.airDrop, targetsShown: false) == .shelf)
    }
}

// MARK: - Module: screenshots, downloads, zip, commands

@MainActor
@Suite(.serialized) struct ShelfPlusModuleTests {
    private func settings(_ change: (ShelfSettings) -> Void = { _ in }) -> (ShelfSettings, () -> Void) {
        let suite = "ai.glancy.tests.shelf.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let s = ShelfSettings(defaults: defaults)
        change(s)
        return (s, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func defaults() {
        let (s, done) = settings(); defer { done() }
        #expect(s.dropTargets && s.downloads)
        #expect(!s.screenshots && !s.screenshotsToShelf)
        // The test process is not an .app: the real folders are never watched.
        #expect(ShelfFolders.system.downloads == nil && ShelfFolders.system.screenshots() == nil)
    }

    @Test func screenshotPeeksAndOptionallyLandsOnTheShelf() async throws {
        let t = Temp(); defer { t.cleanUp() }
        let desktop = t.dir("Desktop"), downloads = t.dir("Downloads")
        let (s, done) = settings { $0.screenshots = true; $0.screenshotsToShelf = true }; defer { done() }
        let shelf = ShelfModule(store: ShelfStore(dir: t.dir("store")), isTransient: { _ in false }, settings: s,
                                folders: ShelfFolders(screenshots: { desktop }, downloads: downloads, settle: .milliseconds(100)))
        let hub = ActivityHub()
        shelf.start(hub: hub)
        defer { shelf.stop() }
        #expect(await eventually { shelf.model.screenshotsStatus == .watching && shelf.model.downloadsStatus == .watching })
        let shot = desktop.appendingPathComponent("Istantanea 2026-10-05 alle 09.41.22.png")
        try makeImage(shot, width: 30, height: 20, type: .png)
        #expect(await eventually { shelf.model.lastScreenshot?.lastPathComponent == shot.lastPathComponent })
        #expect(hub.peek?.module == .shelf)
        #expect(shelf.model.items.map(\.name) == [shot.lastPathComponent])
    }

    @Test func finishedDownloadPeeksWithoutTouchingTheShelf() async throws {
        let t = Temp(); defer { t.cleanUp() }
        let downloads = t.dir("Downloads")
        let (s, done) = settings(); defer { done() }
        let shelf = ShelfModule(store: ShelfStore(dir: t.dir("store")), isTransient: { _ in false }, settings: s,
                                folders: ShelfFolders(screenshots: { nil }, downloads: downloads, settle: .milliseconds(100)))
        let hub = ActivityHub()
        shelf.start(hub: hub)
        defer { shelf.stop() }
        #expect(await eventually { shelf.model.downloadsStatus == .watching })
        let part = t.write("paper.pdf.download", in: downloads, "pdf")
        try FileManager.default.moveItem(at: part, to: downloads.appendingPathComponent("paper.pdf"))
        #expect(await eventually { shelf.model.lastDownloads.map(\.lastPathComponent) == ["paper.pdf"] })
        #expect(hub.peek?.module == .shelf)
        #expect(shelf.model.items.isEmpty)
        // Turning the setting off stops the watcher.
        s.downloads = false
        #expect(shelf.model.downloadsStatus == .off)
        t.write("later.pdf", in: downloads)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(shelf.model.lastDownloads.map(\.lastPathComponent) == ["paper.pdf"])
    }

    @Test func zipDropAddsTheArchiveBesideTheOriginals() async throws {
        let t = Temp(); defer { t.cleanUp() }
        let src = t.dir("src")
        let a = t.write("a.txt", in: src), b = t.write("b.txt", in: src)
        let (s, done) = settings(); defer { done() }
        let shelf = ShelfModule(store: ShelfStore(dir: t.dir("store")), isTransient: { _ in false }, settings: s)
        shelf.start(hub: ActivityHub())
        defer { shelf.stop() }
        shelf.model.dropTargetsShown = true
        shelf.perform(.zip, on: [a, b])
        #expect(!shelf.model.dropTargetsShown)
        #expect(await eventually { shelf.model.busy == 0 && !shelf.model.items.isEmpty })
        #expect(shelf.model.items.map(\.name) == ["Archive.zip"])
        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("Archive.zip").path))
        #expect(shelf.model.items.first?.owned == false)
        // Convert on a shelf item: the result joins the shelf and is selected.
        let png = src.appendingPathComponent("pic.png")
        try makeImage(png, width: 20, height: 10, type: .png)
        shelf.addFiles([png])
        let item = try #require(shelf.model.items.first { $0.name == "pic.png" })
        shelf.convert([item], .jpeg)
        #expect(await eventually { shelf.model.items.contains { $0.name == "pic.jpg" } })
        #expect(shelf.model.selection.count == 1)
    }

    @Test func commandsAndResults() throws {
        let t = Temp(); defer { t.cleanUp() }
        let src = t.dir("src")
        let (s, done) = settings(); defer { done() }
        let shelf = ShelfModule(store: ShelfStore(dir: t.dir("store")), isTransient: { _ in false }, settings: s)
        shelf.start(hub: ActivityHub())
        defer { shelf.stop() }
        #expect(Set(shelf.commands().map(\.id)) == ["shelf.open", "shelf.lastScreenshot", "shelf.lastDownload"])
        shelf.addFiles([t.write("Fattura Città.pdf", in: src), t.write("budget-2026.xlsx", in: src), t.write("notes.txt", in: src)])
        let ids = Set(shelf.commands().map(\.id))
        #expect(ids == ["shelf.open", "shelf.clear", "shelf.airdropLast", "shelf.zipAll", "shelf.lastScreenshot", "shelf.lastDownload"])
        #expect(shelf.commands().allSatisfy { !$0.keywords.isEmpty && !$0.title.isEmpty })

        #expect(shelf.results(for: "").isEmpty)
        #expect(shelf.results(for: "x").isEmpty)
        #expect(shelf.results(for: "citta").map(\.title) == ["Fattura Città.pdf"])   // accent-insensitive
        #expect(shelf.results(for: "2026").map(\.title) == ["budget-2026.xlsx"])
        #expect(shelf.results(for: "zzz").isEmpty)
        // Prefix of the name beats a word inside it beats a substring.
        let ranked = ShelfSearch.matches("no", in: shelf.model.items).map(\.item.name)
        #expect(ranked.first == "notes.txt")
        let hit = try #require(shelf.results(for: "budget").first)
        hit.run()
        #expect(shelf.model.selection == [shelf.model.items.first { $0.name == "budget-2026.xlsx" }!.id])
    }

    @Test func itemMenuActsOnTheSelectionOrTheClickedItem() throws {
        let t = Temp(); defer { t.cleanUp() }
        let src = t.dir("src")
        let (s, done) = settings(); defer { done() }
        let shelf = ShelfModule(store: ShelfStore(dir: t.dir("store")), isTransient: { _ in false }, settings: s)
        shelf.start(hub: ActivityHub())
        defer { shelf.stop() }
        let png = src.appendingPathComponent("pic.png")
        try makeImage(png, width: 10, height: 10, type: .png)
        shelf.addFiles([t.write("a.txt", in: src), png])
        let pic = try #require(shelf.model.items.first { $0.name == "pic.png" })
        let txt = try #require(shelf.model.items.first { $0.name == "a.txt" })

        // Right-click outside the selection: the clicked item becomes the selection.
        let one = shelf.menu(for: txt).items.map(\.title)
        #expect(shelf.model.selection == [txt.id])
        #expect(one.contains("Quick Look") && one.contains("Share") && one.contains("AirDrop") && one.contains("Copy"))
        #expect(one.contains("Show in Finder") && one.contains("Zip") && one.contains("Remove from Shelf"))
        #expect(!one.contains("Convert to JPEG"))   // no image in it

        // Inside a multi-selection: acts on all of it; image actions appear.
        shelf.model.selection = [txt.id, pic.id]
        let many = shelf.menu(for: pic).items.map(\.title)
        #expect(shelf.model.selection == [txt.id, pic.id])
        #expect(many.contains("Copy 2 items") && many.contains("Zip 2 items") && many.contains("Remove 2 from Shelf"))
        #expect(many.contains("Convert to JPEG") && many.contains("Resize to 50%"))
        // Every actionable entry is enabled and wired.
        let remove = try #require(shelf.menu(for: pic).items.first { $0.title == "Remove 2 from Shelf" })
        #expect(remove.isEnabled && remove.action != nil)
        _ = remove.target?.perform(remove.action)
        #expect(shelf.model.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: png.path))
    }
}
