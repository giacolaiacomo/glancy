import AppKit
import Foundation
import Testing
@testable import GlancyKit

// Every pasteboard here is a private named one: the user's clipboard is never touched.

private func withPasteboard<T>(_ body: (NSPasteboard) throws -> T) rethrows -> T {
    let pb = NSPasteboard(name: .init("ai.glancy.test.\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    pb.clearContents()
    return try body(pb)
}

@MainActor
private func classify(_ pb: NSPasteboard, source: String? = nil, excluded: Set<String> = [], paused: Bool = false)
    -> Result<ClipDraft, ClipboardClassifier.SkipError> {
    ClipboardClassifier.classify(PasteboardSnapshot.read(pb), source: source, excluded: excluded, paused: paused)
}

@MainActor
private func kind(_ pb: NSPasteboard) -> ClipKind? { (try? classify(pb).get())?.kind }

private func pngData(width: Int = 1200, height: Int = 800) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ClipImage.encode(ctx.makeImage()!, .png, quality: nil)!
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("glancy-clip-\(UUID().uuidString)", isDirectory: true)
}

private func perms(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func item(_ text: String, pinned: Bool = false, date: Date = .now, app: String? = nil) -> ClipItem {
    ClipItem(kind: .text, text: text, signature: ClipboardClassifier.hash("text", text), date: date, pinned: pinned,
             sourceBundleID: app, sourceName: app)
}

@Suite @MainActor struct ClipboardClassificationTests {
    @Test func plainText() throws {
        try withPasteboard { pb in
            pb.setString("hello world", forType: .string)
            let d = try classify(pb).get()
            #expect(d.kind == .text)
            #expect(d.text == "hello world")
            #expect(d.rtf == nil)
        }
    }

    @Test func richTextKeepsRTFAndPlain() throws {
        try withPasteboard { pb in
            let attr = NSAttributedString(string: "Bold move", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            let rtf = try #require(attr.rtf(from: NSRange(location: 0, length: attr.length)))
            pb.setData(rtf, forType: .rtf)
            pb.setString("Bold move", forType: .string)
            let d = try classify(pb).get()
            #expect(d.kind == .richText)
            #expect(d.text == "Bold move")
            #expect(d.rtf == rtf)
        }
    }

    @Test func urlFromStringOrURLType() throws {
        withPasteboard { pb in
            pb.setString("https://example.com/a?b=1", forType: .string)
            #expect(kind(pb) == .url)
        }
        withPasteboard { pb in
            pb.setString("see https://example.com", forType: .string)
            #expect(kind(pb) == .text)
        }
        try withPasteboard { pb in
            pb.setString("https://swift.org", forType: .URL)
            let d = try classify(pb).get()
            #expect(d.kind == .url)
            #expect(d.text == "https://swift.org")
        }
    }

    @Test func imageAndFiles() throws {
        try withPasteboard { pb in
            pb.setData(pngData(), forType: .png)
            let d = try classify(pb).get()
            #expect(d.kind == .image)
            #expect(d.image != nil)
        }
        try withPasteboard { pb in
            let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.pdf")]
            pb.writeObjects(urls as [NSURL])
            let d = try classify(pb).get()
            #expect(d.kind == .files)
            #expect(d.fileURLs.map(\.lastPathComponent) == ["a.txt", "b.pdf"])
        }
    }

    @Test func sourceOrderDecidesTextVersusImage() {
        // Office: the text first, a picture of it after.
        withPasteboard { pb in
            pb.declareTypes([.string, .png], owner: nil)
            pb.setString("Quarterly numbers", forType: .string)
            pb.setData(pngData(width: 40, height: 20), forType: .png)
            #expect(kind(pb) == .text)
        }
        // "Copy Image": the image first, a caption after.
        withPasteboard { pb in
            pb.declareTypes([.png, .string], owner: nil)
            pb.setData(pngData(width: 40, height: 20), forType: .png)
            pb.setString("photo.png", forType: .string)
            #expect(kind(pb) == .image)
        }
    }

    @Test func whitespaceIsNothing() {
        withPasteboard { pb in
            pb.setString("  \n\t ", forType: .string)
            #expect(classify(pb) == .failure(.init(reason: .empty)))
        }
    }
}

@Suite @MainActor struct ClipboardPrivacyTests {
    @Test func markerTypesAreSkipped() {
        for (raw, reason) in [("org.nspasteboard.ConcealedType", SkipReason.concealed),
                              ("org.nspasteboard.TransientType", .transient),
                              ("org.nspasteboard.AutoGeneratedType", .autoGenerated)] {
            withPasteboard { pb in
                pb.declareTypes([.string, .init(raw)], owner: nil)
                pb.setString("s3cret", forType: .string)
                pb.setData(Data(), forType: .init(raw))
                #expect(classify(pb) == .failure(.init(reason: reason)))
                // Skipped items stop at the type list: the secret is never read.
                #expect(PasteboardSnapshot.read(pb).string == nil)
            }
        }
    }

    @Test func passwordManagersExcludedAppsAndPause() {
        withPasteboard { pb in
            pb.setString("hunter2", forType: .string)
            for id in ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                       "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass",
                       "com.dashlane.Dashlane", "me.proton.pass.electron", "org.keepassxc.keepassxc"] {
                #expect(classify(pb, source: id) == .failure(.init(reason: .passwordManager)), "\(id)")
            }
            #expect(classify(pb, source: "com.tinyspeck.slackmacgap", excluded: ["com.tinyspeck.slackmacgap"])
                    == .failure(.init(reason: .excludedApp)))
            #expect(classify(pb, source: "com.apple.Notes", paused: true) == .failure(.init(reason: .paused)))
            #expect((try? classify(pb, source: "com.apple.Notes").get())?.kind == .text)
        }
    }

    @Test func copyKeyDetection() {
        #expect(CopyKeyTap.isCopyKey(keyCode: 8, flags: .maskCommand, char: 0))
        #expect(CopyKeyTap.isCopyKey(keyCode: 7, flags: .maskCommand, char: 0))
        // Dvorak: the "c" key is elsewhere; the layout character says copy.
        #expect(CopyKeyTap.isCopyKey(keyCode: 34, flags: .maskCommand, char: 0x63))
        #expect(!CopyKeyTap.isCopyKey(keyCode: 8, flags: [], char: 0x63))
        #expect(!CopyKeyTap.isCopyKey(keyCode: 9, flags: .maskCommand, char: 0x76))
        #expect(!CopyKeyTap.isCopyKey(keyCode: 8, flags: [.maskCommand, .maskControl], char: 0))
    }
}

@Suite struct ClipboardHistoryTests {
    @Test func reCopyMovesToTopKeepingPin() {
        let a = item("alpha", pinned: true), b = item("beta"), c = item("gamma")
        let again = item("alpha")
        let r = ClipboardHistory.insert(again, into: [b, a, c])
        #expect(r.list.map(\.text) == ["alpha", "beta", "gamma"])
        #expect(r.list[0].pinned)
        #expect(r.list.count == 3)
        #expect(r.dropped.map(\.id) == [a.id])
    }

    @Test func limitKeepsPinsAndNewest() {
        let pins = (0..<5).map { item("pin \($0)", pinned: true) }
        var list = pins
        for i in 0..<70 { list = ClipboardHistory.insert(item("copy \(i)"), into: list).list }
        #expect(list.filter(\.pinned).count == 5)
        #expect(list.filter { !$0.pinned }.count == ClipLimits.maxItems)
        #expect(list.first?.text == "copy 69")
        #expect(!list.contains { $0.text == "copy 9" })
        #expect(list.contains { $0.text == "copy 10" })
        // The one that falls off is reported, so its blobs can go.
        let r = ClipboardHistory.insert(item("copy 70"), into: list)
        #expect(r.dropped.map(\.text) == ["copy 10"])
    }

    @Test func searchFilters() {
        let list = [item("221B Baker Street, London", app: "Notes"), item("git rebase origin/main", app: "Terminal"),
                    item("Città di Castello", app: "Mail")]
        #expect(ClipboardHistory.filter(list, query: "").count == 3)
        #expect(ClipboardHistory.filter(list, query: "london").map(\.text) == ["221B Baker Street, London"])
        #expect(ClipboardHistory.filter(list, query: "citta").count == 1)            // diacritics
        #expect(ClipboardHistory.filter(list, query: "terminal rebase").count == 1)  // every word, app name
        #expect(ClipboardHistory.filter(list, query: "zzz").isEmpty)
        var files = ClipItem(kind: .files, text: "/tmp/Report.pdf", signature: "f", fileURLs: [URL(fileURLWithPath: "/tmp/Report.pdf")])
        files.sourceName = "Finder"
        #expect(ClipboardHistory.filter([files], query: "report").count == 1)
    }

    @Test func touchMovesUp() {
        let a = item("a"), b = item("b")
        #expect(ClipboardHistory.touch(b.id, in: [a, b]).map(\.text) == ["b", "a"])
    }
}

@Suite struct ClipboardPersistenceTests {
    @Test func roundTripWithPrivatePermissions() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = ClipboardDisk(directory: dir)
        let png = pngData()
        let image = try #require(await disk.ingest(ClipDraft(kind: .image, text: "", image: png, fileURLs: [],
                                                             signature: "img"), source: "com.apple.Preview", sourceName: "Preview"))
        let rtf = Data("{\\rtf1 hi}".utf8)
        let rich = try #require(await disk.ingest(ClipDraft(kind: .richText, text: "hi", rtf: rtf, fileURLs: [], signature: "r"),
                                                  source: nil, sourceName: nil))
        let big = String(repeating: "x", count: ClipLimits.inlineText + 10)
        let long = try #require(await disk.ingest(ClipDraft(kind: .text, text: big, fileURLs: [], signature: "b"),
                                                  source: nil, sourceName: nil))
        var pinned = item("keep me", pinned: true)
        pinned.date = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [image, rich, long, pinned]
        await disk.save(items)

        // Image downsampled to ≤ 512 px, within 2 MB.
        #expect(max(image.imageSize?.width ?? 0, image.imageSize?.height ?? 0) == 512)
        let imageFile = dir.appendingPathComponent("blobs/\(image.imageBlob!)")
        #expect(try Data(contentsOf: imageFile).count <= ClipLimits.imageBytes)
        // Big text: the head inline, the whole in a blob.
        #expect(long.textBlob != nil)
        #expect(long.text.utf8.count == ClipLimits.inlineText)

        let loaded = await ClipboardDisk(directory: dir).load()
        #expect(loaded == items)

        #expect(perms(dir) == 0o700)
        #expect(perms(dir.appendingPathComponent("blobs")) == 0o700)
        #expect(perms(dir.appendingPathComponent("index.json")) == 0o600)
        for name in items.flatMap(\.blobs) {
            #expect(perms(dir.appendingPathComponent("blobs/\(name)")) == 0o600, "\(name)")
        }

        // Clear all leaves nothing behind.
        await disk.wipe()
        #expect(await disk.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("blobs").path))
    }

    @Test func sweepRemovesOrphans() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = ClipboardDisk(directory: dir)
        let kept = try #require(await disk.ingest(ClipDraft(kind: .image, text: "", image: pngData(width: 20, height: 20),
                                                            fileURLs: [], signature: "k"), source: nil, sourceName: nil))
        let orphan = try #require(await disk.ingest(ClipDraft(kind: .image, text: "", image: pngData(width: 30, height: 20),
                                                              fileURLs: [], signature: "o"), source: nil, sourceName: nil))
        await disk.sweep(keeping: [kept])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("blobs/\(kept.imageBlob!)").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("blobs/\(orphan.imageBlob!)").path))
    }
}

@Suite @MainActor struct ClipboardModelTests {
    /// Waits for the model's off-main ingest to land.
    private func settle(_ until: () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func capturesThenOwnWriteIsNotRecaptured() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pb = NSPasteboard(name: .init("ai.glancy.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let model = ClipboardModel(disk: ClipboardDisk(directory: dir, debounce: .milliseconds(1)),
                                   settings: ClipboardSettings(defaults: UserDefaults(suiteName: "ai.glancy.test.\(UUID())")!),
                                   pasteboard: pb)

        // Unchanged pasteboard: nothing to do.
        model.check(source: nil)
        #expect(model.items.isEmpty)

        pb.clearContents(); pb.setString("first", forType: .string)
        model.check(source: nil)
        await settle { model.items.count == 1 }
        pb.clearContents(); pb.setString("second", forType: .string)
        model.check(source: nil)
        await settle { model.items.count == 2 }
        #expect(model.items.map(\.text) == ["second", "first"])

        // Copy "first" back: it goes to the top, the pasteboard carries our marker.
        var chosen: ClipItem?
        model.onChosen = { chosen = $0 }
        model.choose(model.items[1])
        #expect(chosen?.text == "first")
        #expect(model.items.map(\.text) == ["first", "second"])
        #expect(pb.string(forType: .string) == "first")
        #expect(pb.types?.contains(.glancyOwn) == true)

        // Even if the change count is seen as new (another Glancy wrote it), it is skipped.
        model.lastChangeCount = -1
        model.check(source: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.items.count == 2)
        #expect(classify(pb) == .failure(.init(reason: .own)))

        // Re-copying the same text from elsewhere de-dups onto the existing item.
        pb.clearContents(); pb.setString("second", forType: .string)
        model.check(source: nil)
        #expect(model.items.map(\.text) == ["second", "first"])
    }

    @Test func searchSelectionAndKeyboard() {
        let model = ClipboardModel(disk: ClipboardDisk(directory: tempDir()),
                                   settings: ClipboardSettings(defaults: UserDefaults(suiteName: "ai.glancy.test.\(UUID())")!),
                                   pasteboard: NSPasteboard(name: .init("ai.glancy.test.\(UUID().uuidString)")))
        model.items = [item("recent one"), item("pinned note", pinned: true), item("another recent")]
        // Drawing order: pinned first.
        #expect(model.shown.map(\.text) == ["pinned note", "recent one", "another recent"])
        model.moveSelection(5)
        #expect(model.selection == 2)
        model.query = "recent"
        #expect(model.selection == 0)
        #expect(model.shown.map(\.text) == ["recent one", "another recent"])
        #expect(model.wantsKeyFocus == false)
    }

    @Test func excludeRemovesThatAppsItems() {
        let model = ClipboardModel(disk: ClipboardDisk(directory: tempDir()),
                                   settings: ClipboardSettings(defaults: UserDefaults(suiteName: "ai.glancy.test.\(UUID())")!),
                                   pasteboard: NSPasteboard(name: .init("ai.glancy.test.\(UUID().uuidString)")))
        model.items = [item("a", app: "com.x"), item("b", app: "com.y")]
        model.exclude(bundleID: "com.x", name: "X")
        #expect(model.items.map(\.text) == ["b"])
        #expect(model.settings.excludedIDs == ["com.x"])
    }
}
