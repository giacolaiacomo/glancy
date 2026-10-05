import AppKit
import SwiftUI

// Screenshots and finished downloads landing in the notch.

extension ShelfModule {
    static let screenshotPeekSeconds: TimeInterval = 6
    static let downloadPeekSeconds: TimeInterval = 5

    /// (Re)starts the folder watchers the settings ask for. Called at start, on a settings
    /// change, and when the panel opens with a moved screenshot location.
    func applyFolderSettings() {
        stopFolderWatchers()
        let shots = settings.screenshots ? folders.screenshots() : nil
        let prefix = folders.screenshotPrefix()
        model.screenshotsFolder = shots
        if let shots {
            let w = ShelfFolderWatcher(folder: shots, settle: folders.settle) { ShelfFolderRules.isScreenshot($0, customPrefix: prefix) }
            w.onFiles = { [weak self] urls in self?.screenshotsArrived(urls) }
            screenshotWatcher = w
            Task { [weak self] in
                let status = await w.start()
                if let self, self.screenshotWatcher === w { self.model.screenshotsStatus = status }
            }
        } else {
            model.screenshotsStatus = .off
        }
        if settings.downloads, let downloads = folders.downloads {
            // When screenshots land in Downloads too, they are the screenshot watcher's.
            let sameFolder = shots?.standardizedFileURL == downloads.standardizedFileURL
            let w = ShelfFolderWatcher(folder: downloads, settle: folders.settle) { name in
                ShelfFolderRules.isDownload(name) && !(sameFolder && ShelfFolderRules.isScreenshot(name, customPrefix: prefix))
            }
            w.onFiles = { [weak self] urls in self?.downloadsArrived(urls) }
            downloadWatcher = w
            Task { [weak self] in
                let status = await w.start()
                if let self, self.downloadWatcher === w { self.model.downloadsStatus = status }
            }
        } else {
            model.downloadsStatus = .off
        }
    }

    func stopFolderWatchers() {
        screenshotWatcher?.stop(); screenshotWatcher = nil
        downloadWatcher?.stop(); downloadWatcher = nil
    }

    // MARK: Arrivals

    func screenshotsArrived(_ urls: [URL]) {
        // A burst (several displays at once) shows the last one; all are kept if asked.
        guard let last = urls.last else { return }
        model.lastScreenshot = last
        if settings.screenshotsToShelf { add(urls.map { ($0, false) }) }
        showScreenshotPeek(last)
    }

    func downloadsArrived(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        model.lastDownloads = urls
        showDownloadPeek(urls)
    }

    func showScreenshotPeek(_ url: URL) {
        hub?.show(PeekEvent(module: .shelf, duration: Self.screenshotPeekSeconds,
                            content: AnyView(ShelfScreenshotPeek(shelf: self, url: url))))
    }

    func showDownloadPeek(_ urls: [URL]) {
        hub?.show(PeekEvent(module: .shelf, duration: Self.downloadPeekSeconds,
                            content: AnyView(ShelfDownloadPeek(shelf: self, urls: urls))))
    }

    // MARK: Peek actions

    /// The screenshot as an image on the clipboard (paste into a chat, a doc, a mail).
    func copyImage(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { Self.copy([url]); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        note(symbol: "doc.on.doc", L10n.tr("Copied"))
    }

    /// Opens Preview, where Markup is one click away.
    func annotate(_ url: URL) {
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        hub?.requestClose()
    }

    /// To the Trash (undoable in Finder), and off the shelf if it was kept.
    func trash(_ url: URL) {
        let key = ShelfList.key(url.path)
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            let failed = error != nil
            Task { @MainActor in
                guard let self, !failed else { return }
                let gone = Set(self.model.items.filter { ShelfList.key($0.path) == key }.map(\.id))
                if !gone.isEmpty { self.remove(gone) }
                if self.model.lastScreenshot.map({ ShelfList.key($0.path) }) == key { self.model.lastScreenshot = nil }
                self.hub?.requestClose()
            }
        }
    }

    func keep(_ url: URL) {
        add([(url, false)])
        note(symbol: "tray.and.arrow.down.fill", L10n.tr("On the shelf"))
    }

    /// "Show last screenshot / download" (command bar): the peek again, if the file is still there.
    func showLastScreenshot() {
        guard let url = model.lastScreenshot, FileManager.default.fileExists(atPath: url.path) else {
            note(symbol: "camera.viewfinder", L10n.tr("No new screenshot yet")); return
        }
        hub?.requestClose()
        showScreenshotPeek(url)
    }

    func showLastDownload() {
        let urls = model.lastDownloads.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { note(symbol: "arrow.down.circle", L10n.tr("No new download yet")); return }
        hub?.requestClose()
        showDownloadPeek(urls)
    }
}
