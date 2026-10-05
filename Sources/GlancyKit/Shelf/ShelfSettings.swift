import Foundation

/// The Shelf's switches (Settings → Shelf), in `UserDefaults`.
///
/// Defaults, and why:
/// - Drop targets ON: they only appear while files are dragged to the notch; the Shelf stays the
///   default target, so nothing changes for a plain drop.
/// - Finished downloads ON (asked for): one quiet peek per finished download is the useful half of
///   this feature. macOS asks once for the Downloads folder (Files and Folders privacy applies to
///   unsandboxed apps too); a refusal just turns the line in Settings amber.
/// - Screenshots OFF: macOS already shows its own floating thumbnail for every screenshot, so a
///   second preview is noise until asked for, and the Desktop (the usual location) is another
///   privacy prompt nobody should get on first launch for a feature they didn't pick.
/// - Keep screenshots on the shelf OFF: the peek has "Keep"; filling the shelf with every
///   screenshot would push out what the user parked on purpose.
@MainActor @Observable
public final class ShelfSettings {
    public static let dropTargetsKey = "glancy.shelf.dropTargets"
    public static let screenshotsKey = "glancy.shelf.screenshots"
    public static let screenshotsToShelfKey = "glancy.shelf.screenshotsToShelf"
    public static let downloadsKey = "glancy.shelf.downloads"

    public var dropTargets: Bool { didSet { defaults.set(dropTargets, forKey: Self.dropTargetsKey) } }
    public var screenshots: Bool { didSet { defaults.set(screenshots, forKey: Self.screenshotsKey); onChange?() } }
    public var screenshotsToShelf: Bool { didSet { defaults.set(screenshotsToShelf, forKey: Self.screenshotsToShelfKey) } }
    public var downloads: Bool { didSet { defaults.set(downloads, forKey: Self.downloadsKey); onChange?() } }

    /// The module restarts its folder watchers.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dropTargets = defaults.object(forKey: Self.dropTargetsKey) as? Bool ?? true
        screenshots = defaults.object(forKey: Self.screenshotsKey) as? Bool ?? false
        screenshotsToShelf = defaults.object(forKey: Self.screenshotsToShelfKey) as? Bool ?? false
        downloads = defaults.object(forKey: Self.downloadsKey) as? Bool ?? true
    }
}

/// Where the shelf's folder watchers look. The app watches the real folders; tests, the renderer
/// and command-line tools pass their own (or none), so they never touch — or trigger a privacy
/// prompt for — the user's Desktop and Downloads.
public struct ShelfFolders: Sendable {
    public var screenshots: @Sendable () -> URL?
    public var screenshotPrefix: @Sendable () -> String?
    public var downloads: URL?
    public var settle: Duration

    public init(screenshots: @escaping @Sendable () -> URL?, screenshotPrefix: @escaping @Sendable () -> String? = { nil },
                downloads: URL?, settle: Duration = .seconds(1)) {
        self.screenshots = screenshots; self.screenshotPrefix = screenshotPrefix
        self.downloads = downloads; self.settle = settle
    }

    public static let none = ShelfFolders(screenshots: { nil }, downloads: nil)

    /// The user's real folders — only inside an .app bundle (not `swift test`, not glancy-render).
    public static var system: ShelfFolders {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .none }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return ShelfFolders(screenshots: { ShelfFolderRules.screenshotFolder() },
                            screenshotPrefix: { ShelfFolderRules.screenshotPrefix() },
                            downloads: downloads)
    }
}
