// Tiling — what the user chose: grids per display, default strategy, saved layouts, options.
// Decoded field by field (Tessera's lenient pattern): an unknown key is ignored, a missing or
// malformed one falls back, so a file written by another version never resets someone's setup.
// Nothing learned at run time (window minimums, outcomes) is ever stored here.

import CoreGraphics
import Foundation

/// One window's place in a saved layout.
public struct LayoutPlacement: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String
    /// Disambiguates several windows of the same app (case-insensitive substring of the title).
    public var titleContains: String?
    public var cell: CellRect
    /// Display UUID; nil = the display the window is already on.
    public var displayID: String?

    public init(bundleID: String, titleContains: String? = nil, cell: CellRect, displayID: String? = nil) {
        self.bundleID = bundleID; self.titleContains = titleContains; self.cell = cell; self.displayID = displayID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = c.lenient(.bundleID, "")
        titleContains = c.lenient(.titleContains, nil)
        cell = c.lenient(.cell, CellRect(col: 0, row: 0))
        displayID = c.lenient(.displayID, nil)
    }
}

/// A scene ("Dev", "Call") applied in one go; digits on the Windows tab pick one.
public struct SavedLayout: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var placements: [LayoutPlacement]

    public init(id: UUID = UUID(), name: String, placements: [LayoutPlacement]) {
        self.id = id; self.name = name; self.placements = placements
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID())
        name = c.lenient(.name, "")
        placements = c.lenient(.placements, [])
    }
}

public struct TilingConfig: Codable, Equatable, Sendable {
    /// Display UUID (`CGDisplayCreateUUIDFromDisplayID`) → grid.
    public var grids: [String: GridSpec] = [:]
    public var defaultStrategy: ArrangeStrategy = .balanced
    /// Width of the master tile in "master + stack".
    public var masterFraction: CGFloat = 0.6
    public var layouts: [SavedLayout] = []
    /// Drop a brand-new window into the largest free area of its display (RESEARCH §3.3). Off.
    public var autoFitNewWindows = false
    /// Dragging a tiled window away gives it back the size it had before it was tiled.
    public var restoreSizeOnDragAway = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grids = c.lenient(.grids, [:])
        defaultStrategy = c.lenient(.defaultStrategy, .balanced)
        masterFraction = c.lenient(.masterFraction, 0.6)
        layouts = c.lenient(.layouts, [])
        autoFitNewWindows = c.lenient(.autoFitNewWindows, false)
        restoreSizeOnDragAway = c.lenient(.restoreSizeOnDragAway, true)
    }

    public func grid(for displayID: String) -> GridSpec {
        (grids[displayID] ?? .default).clamped()
    }

    // MARK: Persistence (~/Library/Application Support/Glancy/tiling.json)

    public static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glancy", isDirectory: true)
        return dir.appendingPathComponent("tiling.json")
    }

    /// The stored config, or the defaults when the file is missing or unreadable.
    public static func load(from url: URL = defaultURL) -> TilingConfig {
        guard let data = try? Data(contentsOf: url) else { return TilingConfig() }
        return (try? JSONDecoder().decode(TilingConfig.self, from: data)) ?? TilingConfig()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
