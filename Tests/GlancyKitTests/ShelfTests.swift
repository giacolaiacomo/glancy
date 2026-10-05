import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import GlancyKit

/// A scratch folder per test, removed at the end.
private struct Scratch {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-shelf-\(UUID().uuidString)", isDirectory: true)
    var storeDir: URL { root.appendingPathComponent("store", isDirectory: true) }
    var store: ShelfStore { ShelfStore(dir: storeDir) }

    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    @discardableResult
    func file(_ name: String, _ text: String = "hello") -> URL {
        let url = root.appendingPathComponent("files", isDirectory: true).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        return url
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ShelfStoreTests {
    @Test func bookmarkResolvesTempFileAndFollowsRename() throws {
        let s = Scratch(); defer { s.cleanUp() }
        let url = s.file("report.pdf")
        let item = try ShelfStore.item(for: url, owned: false)
        let (resolved, _) = try #require(ShelfStore.resolve(item))
        #expect(resolved.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
        // Bookmarks follow the file, not the path.
        let moved = url.deletingLastPathComponent().appendingPathComponent("report-final.pdf")
        try FileManager.default.moveItem(at: url, to: moved)
        let (after, _) = try #require(ShelfStore.resolve(item))
        #expect(after.lastPathComponent == "report-final.pdf")
    }

    @Test func persistAndRestoreDropsMissingFiles() throws {
        let s = Scratch(); defer { s.cleanUp() }
        let a = s.file("a.txt"), b = s.file("b.txt")
        let items = try [ShelfStore.item(for: a, owned: false), ShelfStore.item(for: b, owned: false)]
        s.store.save(items)
        #expect(s.store.load().map(\.id) == items.map(\.id))
        try FileManager.default.removeItem(at: b)
        let restored = s.store.load()
        #expect(restored.map(\.id) == [items[0].id])
        // The pruned list was written back.
        let data = try Data(contentsOf: s.store.indexURL)
        #expect(try JSONDecoder().decode([ShelfItem].self, from: data).count == 1)
    }

    @Test func restoreFollowsRenamedFile() throws {
        let s = Scratch(); defer { s.cleanUp() }
        let a = s.file("draft.key")
        s.store.save([try ShelfStore.item(for: a, owned: false)])
        let renamed = a.deletingLastPathComponent().appendingPathComponent("keynote.key")
        try FileManager.default.moveItem(at: a, to: renamed)
        let item = try #require(s.store.load().first)
        #expect(item.name == "keynote.key")
        #expect(URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
    }

    @Test func unreadableBookmarkFallsBackToPathAndIsRefreshed() throws {
        let s = Scratch(); defer { s.cleanUp() }
        let a = s.file("notes.md")
        // A bookmark another signature made (or garbage): the file is still where it was.
        let foreign = ShelfItem(name: "notes.md", bookmark: Data("not a bookmark".utf8), scoped: true, path: a.path, owned: false)
        s.store.save([foreign])
        let item = try #require(s.store.load().first)
        #expect(item.id == foreign.id)
        #expect(item.bookmark != foreign.bookmark)
        #expect(ShelfStore.resolve(item) != nil)
    }

    @Test func stagedTextAndLinkFiles() throws {
        let s = Scratch(); defer { s.cleanUp() }
        let txt = try s.store.stageText("Buy milk: 2 litres\nand bread")
        #expect(txt.lastPathComponent == "Buy milk- 2 litres.txt")
        #expect(try String(contentsOf: txt, encoding: .utf8) == "Buy milk: 2 litres\nand bread")
        let link = try s.store.stageLink(URL(string: "https://www.apple.com/macbook-pro/")!)
        #expect(link.lastPathComponent == "www.apple.com.webloc")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: link), format: nil) as? [String: String]
        #expect(plist?["URL"] == "https://www.apple.com/macbook-pro/")
        #expect(txt.path.hasPrefix(s.store.filesDir.path))
        #expect(ShelfStore.fileName(for: "   ", fallback: "Text") == "Text")
        #expect(ShelfStore.fileName(for: ".hidden", fallback: "Text") == "Text")
    }

    @Test func removeStagedOnlyInsideShelfFiles() throws {
        let s = Scratch(); defer { s.cleanUp() }
        let staged = try s.store.stageText("note")
        let owned = try ShelfStore.item(for: staged, owned: true)
        s.store.removeStaged(owned)
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        // A user's file is never deleted, even if wrongly marked as owned.
        let user = s.file("keep.txt")
        var forged = try ShelfStore.item(for: user, owned: true)
        forged.owned = true
        s.store.removeStaged(forged)
        #expect(FileManager.default.fileExists(atPath: user.path))
    }

    @Test func transientPaths() {
        #expect(ShelfStore.isTransient(URL(fileURLWithPath: "/private/var/folders/xy/T/.com.apple.Foundation.NSItemProvider.abc/Mail.eml")))
        #expect(ShelfStore.isTransient(FileManager.default.temporaryDirectory.appendingPathComponent("x.png")))
        #expect(!ShelfStore.isTransient(URL(fileURLWithPath: "/Users/someone/Documents/x.png")))
    }
}

@Suite struct ShelfListTests {
    private func item(_ path: String, owned: Bool = false) -> ShelfItem {
        ShelfItem(name: (path as NSString).lastPathComponent, bookmark: Data(), scoped: false, path: path, owned: owned)
    }

    @Test func newestFirst() {
        let a = item("/x/a"), b = item("/x/b")
        let (list, removed) = ShelfList.adding([b], to: [a])
        #expect(list.map(\.path) == ["/x/b", "/x/a"])
        #expect(removed.isEmpty)
    }

    @Test func dedupeMovesExistingToFrontKeepingIdentity() {
        let a = item("/x/a"), b = item("/x/b")
        let again = item("/x/./a")
        let (list, removed) = ShelfList.adding([again], to: [b, a])
        #expect(list.map(\.id) == [a.id, b.id])
        #expect(removed.map(\.id) == [again.id])
        // Duplicates inside one drop collapse too.
        let (list2, _) = ShelfList.adding([item("/x/c"), item("/x/c")], to: [])
        #expect(list2.count == 1)
    }

    @Test func limitEvictsOldest() {
        let old = (0..<ShelfStore.limit).map { item("/x/\($0)") }
        let (list, removed) = ShelfList.adding([item("/x/new"), item("/x/new2")], to: old)
        #expect(list.count == ShelfStore.limit)
        #expect(list.first?.path == "/x/new")
        #expect(removed.map(\.path) == ["/x/\(ShelfStore.limit - 2)", "/x/\(ShelfStore.limit - 1)"])
    }
}

@MainActor
@Suite struct ShelfModuleTests {
    @Test func addPersistsAcrossRelaunchAndRemoveDeletesStagedOnly() throws {
        let s = Scratch(); defer { s.cleanUp() }
        let a = s.file("a.txt"), b = s.file("b.txt")
        let hub = ActivityHub()
        let shelf = ShelfModule(store: s.store, isTransient: { _ in false })
        shelf.start(hub: hub)
        #expect(shelf.homeCard() == nil)
        shelf.addFiles([a, b, a])
        #expect(shelf.model.items.map(\.name) == ["a.txt", "b.txt"])
        #expect(shelf.homeCard() != nil)
        #expect(hub.top == nil)   // no activity at rest
        shelf.stop()

        let again = ShelfModule(store: s.store, isTransient: { _ in false })
        again.start(hub: ActivityHub())
        #expect(again.model.items.map(\.name) == ["a.txt", "b.txt"])
        again.clear()
        #expect(again.model.items.isEmpty)
        // Removing from the shelf never touches the user's files.
        #expect(FileManager.default.fileExists(atPath: a.path))
        again.stop()
    }

    @Test func transientFilesAreCopiedIn() throws {
        let s = Scratch(); defer { s.cleanUp() }
        let staged = s.file("Invoice.pdf", "pdf")
        let shelf = ShelfModule(store: s.store, isTransient: { _ in true })
        shelf.start(hub: ActivityHub())
        shelf.addFiles([staged])
        let item = try #require(shelf.model.items.first)
        #expect(item.owned)
        #expect(item.path.hasPrefix(s.store.filesDir.resolvingSymlinksInPath().path) || item.path.hasPrefix(s.store.filesDir.path))
        // The source can vanish (as Foundation's staging does): the shelf keeps its copy.
        try FileManager.default.removeItem(at: staged)
        #expect(FileManager.default.fileExists(atPath: item.path))
        shelf.remove([item.id])
        #expect(!FileManager.default.fileExists(atPath: item.path))
        shelf.stop()
    }
}

/// Promise source for the classification test (never asked to write).
private final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Message.txt" }
    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
@Suite struct ShelfDropTests {
    private func pasteboard(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        fill(pb)
        return pb
    }

    @Test func fileURLs() {
        let s = Scratch(); defer { s.cleanUp() }
        let a = s.file("a.png"), b = s.file("b.png")
        let pb = pasteboard { $0.writeObjects([a as NSURL, b as NSURL]) }
        #expect(ShelfDrop.classify(pb) == .files([a, b]))
        pb.releaseGlobally()
    }

    @Test func missingFileURLFallsThrough() {
        let pb = pasteboard {
            $0.writeObjects([URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png") as NSURL])
        }
        if case .files = ShelfDrop.classify(pb) { Issue.record("a missing file must not classify as files") }
        pb.releaseGlobally()
    }

    @Test func filePromise() {
        let delegate = PromiseDelegate()
        let provider = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: delegate)
        let pb = pasteboard { $0.writeObjects([provider]) }
        #expect(ShelfDrop.classify(pb) == .promises(1))
        pb.releaseGlobally()
    }

    @Test func webURL() {
        let link = URL(string: "https://github.com/apple/swift")!
        let pb = pasteboard { $0.writeObjects([link as NSURL]) }
        #expect(ShelfDrop.classify(pb) == .link(link))
        pb.releaseGlobally()
    }

    @Test func linkTypedAsText() {
        let pb = pasteboard { $0.setString("https://example.com/a?b=c", forType: .string) }
        #expect(ShelfDrop.classify(pb) == .link(URL(string: "https://example.com/a?b=c")!))
        pb.releaseGlobally()
    }

    @Test func plainText() {
        let pb = pasteboard { $0.setString("  Ship it on Friday\nthen rest  ", forType: .string) }
        #expect(ShelfDrop.classify(pb) == .text("Ship it on Friday\nthen rest"))
        pb.releaseGlobally()
    }

    @Test func emptyIsNil() {
        let pb = pasteboard { _ in }
        #expect(ShelfDrop.classify(pb) == nil)
        pb.releaseGlobally()
    }
}
