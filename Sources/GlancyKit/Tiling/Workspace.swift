// Tiling — saved workspaces: every tileable window of every display, as fractions of its display's
// usable frame, with the display setup it was saved on. Pure: capture, display matching, window
// matching (bundle ID + title similarity) and the plans that put windows back. Launching apps and
// waiting for their windows lives with the Windows tab (Windows/WorkspaceRestorer.swift).
//
// Stored in ~/Library/Application Support/Glancy/workspaces.json, decoded leniently so a file
// from another version never loses someone's workspaces.

import CoreGraphics
import Foundation

/// A rect as fractions of a display's usable frame, measured from its top-left corner (y down,
/// as people read a screen). Survives a change of resolution or display size.
public struct UnitRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = c.lenient(.x, 0); y = c.lenient(.y, 0); w = c.lenient(.w, 0.5); h = c.lenient(.h, 0.5)
    }

    /// `frame` (Cocoa) relative to `usable` (Cocoa). Rounded to 1/10 000.
    public static func from(_ frame: CGRect, in usable: CGRect) -> UnitRect {
        guard usable.width > 0, usable.height > 0 else { return UnitRect(x: 0, y: 0, w: 1, h: 1) }
        func r(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }
        return UnitRect(x: r((frame.minX - usable.minX) / usable.width),
                        y: r((usable.maxY - frame.maxY) / usable.height),
                        w: r(frame.width / usable.width),
                        h: r(frame.height / usable.height))
    }

    /// The Cocoa frame on `usable`, in whole points and kept inside it.
    public func frame(in usable: CGRect) -> CGRect {
        let width = min(usable.width, max(1, (w * usable.width).rounded()))
        let height = min(usable.height, max(1, (h * usable.height).rounded()))
        let minX = usable.minX + (x * usable.width).rounded()
        let maxY = usable.maxY - (y * usable.height).rounded()
        let r = CGRect(x: minX, y: maxY - height, width: width, height: height)
        return PlacementMath.pushInside(r, usable)
    }
}

/// The display a workspace window was on: UUID first, then name + size when the UUID changed
/// (some docks and adapters hand out a new one), then size alone.
public struct WorkspaceDisplay: Codable, Equatable, Hashable, Sendable {
    public var uuid: String
    public var name: String
    /// Points (the display's full frame).
    public var width: Double
    public var height: Double
    public var builtIn: Bool

    public init(uuid: String, name: String, width: Double, height: Double, builtIn: Bool) {
        self.uuid = uuid; self.name = name; self.width = width; self.height = height; self.builtIn = builtIn
    }

    public init(_ d: Display) {
        self.init(uuid: d.id, name: d.name, width: Double(d.frame.width), height: Double(d.frame.height), builtIn: d.isBuiltIn)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = c.lenient(.uuid, ""); name = c.lenient(.name, ""); width = c.lenient(.width, 0); height = c.lenient(.height, 0)
        builtIn = c.lenient(.builtIn, false)
    }

    func sameSize(_ d: Display) -> Bool { abs(width - Double(d.frame.width)) < 1 && abs(height - Double(d.frame.height)) < 1 }
}

/// One window of a workspace.
public struct WorkspaceWindow: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    /// The title when saved: matching prefers the window whose title is most alike.
    public var title: String
    /// Index into the workspace's `displays`.
    public var display: Int
    public var frame: UnitRect
    /// Stacking order when saved, 0 = frontmost.
    public var order: Int

    public init(bundleID: String, appName: String, title: String, display: Int, frame: UnitRect, order: Int) {
        self.bundleID = bundleID; self.appName = appName; self.title = title; self.display = display
        self.frame = frame; self.order = order
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = c.lenient(.bundleID, ""); appName = c.lenient(.appName, ""); title = c.lenient(.title, "")
        display = c.lenient(.display, 0); frame = c.lenient(.frame, UnitRect(x: 0, y: 0, w: 0.5, h: 0.5))
        order = c.lenient(.order, 0)
    }
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    /// Every display connected when it was saved (the setup "apply on connect" recognises).
    public var displays: [WorkspaceDisplay]
    /// Front to back.
    public var windows: [WorkspaceWindow]
    /// Restores it from anywhere. No modifiers = none (the default).
    public var hotkey: Hotkey
    /// Restore it automatically when this display setup connects. Off by default.
    public var applyOnConnect: Bool

    public init(id: UUID = UUID(), name: String, created: Date = .now, displays: [WorkspaceDisplay],
                windows: [WorkspaceWindow], hotkey: Hotkey = Hotkey(keyCode: 0, modifiers: 0), applyOnConnect: Bool = false) {
        self.id = id; self.name = name; self.created = created; self.displays = displays; self.windows = windows
        self.hotkey = hotkey; self.applyOnConnect = applyOnConnect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, UUID()); name = c.lenient(.name, ""); created = c.lenient(.created, Date.now)
        displays = c.lenient(.displays, []); windows = c.lenient(.windows, [])
        hotkey = c.lenient(.hotkey, Hotkey(keyCode: 0, modifiers: 0)); applyOnConnect = c.lenient(.applyOnConnect, false)
    }

    /// Apps in it, in first-seen order.
    public var bundleIDs: [String] {
        var seen = Set<String>()
        return windows.map(\.bundleID).filter { seen.insert($0).inserted }
    }

    /// Displays that hold at least one of its windows.
    public var usedDisplays: Int { Set(windows.map(\.display)).count }
}

/// What is on disk.
public struct WorkspaceFile: Codable, Equatable, Sendable {
    public var version = 1
    public var workspaces: [Workspace] = []

    public init(workspaces: [Workspace] = []) { self.workspaces = workspaces }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(.version, 1)
        workspaces = c.lenient(.workspaces, [])
    }

    public static var defaultURL: URL {
        TilingConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("workspaces.json")
    }

    public static func load(from url: URL) -> WorkspaceFile {
        guard let data = try? Data(contentsOf: url) else { return WorkspaceFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WorkspaceFile.self, from: data)) ?? WorkspaceFile()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// What restoring a workspace would do with the windows there are now.
public struct WorkspacePlan: Sendable, Equatable {
    /// One plan per display touched; committed together as one undoable operation.
    public var plans: [ArrangePlan]
    /// Workspace window index → the live window it went to.
    public var matched: [Int: CGWindowID]
    /// Workspace window indices with no live window.
    public var unmatched: [Int]
    public var moveCount: Int { plans.reduce(0) { $0 + $1.moves.count } }
}

public enum WorkspacePlanner {

    // MARK: Capture

    /// Every tileable window with a bundle ID, front to back, on the displays there are now.
    public static func capture(name: String, windows: [TrackedWindow], displays: [Display], id: UUID = UUID(),
                               created: Date = .now) -> Workspace {
        let frames = displays.map(\.frame)
        var entries: [WorkspaceWindow] = []
        for w in windows where w.isTileable {
            guard let bundleID = w.bundleID, !bundleID.isEmpty,
                  let i = ScreenSpace.bestIndex(for: w.frame, among: frames) else { continue }
            entries.append(WorkspaceWindow(bundleID: bundleID, appName: w.appName, title: String(w.title.prefix(160)),
                                           display: i, frame: UnitRect.from(w.frame, in: displays[i].usableFrame),
                                           order: entries.count))
        }
        // Whole seconds: what the ISO 8601 file keeps.
        let created = Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded(.down))
        return Workspace(id: id, name: name, created: created, displays: displays.map(WorkspaceDisplay.init), windows: entries)
    }

    /// "Workspace N", the first N not taken.
    public static func defaultName(existing: [String], format: (Int) -> String) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        var n = existing.count + 1
        for k in 1...(existing.count + 1) where !taken.contains(format(k).lowercased()) { n = k; break }
        return format(n)
    }

    // MARK: Displays

    /// Saved display index → a display connected now. UUID first, then name + size, then size,
    /// then built-in to built-in. Each connected display is used once.
    public static func resolve(_ saved: [WorkspaceDisplay], current: [Display]) -> [Int: Display] {
        var out: [Int: Display] = [:]
        var free = current
        let passes: [(WorkspaceDisplay, Display) -> Bool] = [
            { s, d in s.uuid == d.id },
            { s, d in !s.name.isEmpty && s.name == d.name && s.sameSize(d) },
            { s, d in s.sameSize(d) && s.builtIn == d.isBuiltIn },
            { s, d in s.builtIn && d.isBuiltIn },
        ]
        for pass in passes {
            for (i, s) in saved.enumerated() where out[i] == nil {
                guard let j = free.firstIndex(where: { pass(s, $0) }) else { continue }
                out[i] = free.remove(at: j)
            }
        }
        return out
    }

    /// The connected displays are the ones it was saved on (same count, each one recognised by
    /// UUID or by name + size). What "apply when this display setup connects" checks.
    public static func setupMatches(_ w: Workspace, current: [Display]) -> Bool {
        guard !w.displays.isEmpty, w.displays.count == current.count else { return false }
        var free = current
        for s in w.displays {
            guard let j = free.firstIndex(where: { $0.id == s.uuid })
                    ?? free.firstIndex(where: { !s.name.isEmpty && $0.name == s.name && s.sameSize($0) }) else { return false }
            free.remove(at: j)
        }
        return true
    }

    /// The setup as a key: changes when a display comes or goes (not when the Dock resizes).
    public static func setupKey(_ displays: [Display]) -> String {
        displays.map { "\($0.id)@\(Int($0.frame.width))x\(Int($0.frame.height))" }.sorted().joined(separator: "|")
    }

    // MARK: Windows

    /// 1 = same title, 0 = nothing in common. Case and punctuation do not count; an empty title on
    /// either side is neutral (0.3) so the bundle ID still decides.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalise(a), y = normalise(b)
        if x.isEmpty || y.isEmpty { return 0.3 }
        if x == y { return 1 }
        if x.contains(y) || y.contains(x) { return 0.8 }
        let tx = Set(x.split(separator: " ")), ty = Set(y.split(separator: " "))
        let union = tx.union(ty).count
        guard union > 0 else { return 0 }
        return 0.7 * Double(tx.intersection(ty).count) / Double(union)
    }

    private static func normalise(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Workspace window index → live window: same bundle ID, the most alike titles first, then the
    /// saved order, then the frontmost live window. Each live window is used once.
    public static func match(_ entries: [WorkspaceWindow], windows: [TrackedWindow]) -> [Int: CGWindowID] {
        struct Pair { let entry: Int; let window: Int; let score: Double }
        var pairs: [Pair] = []
        for (i, e) in entries.enumerated() {
            for (j, w) in windows.enumerated() where w.isTileable && w.bundleID == e.bundleID {
                pairs.append(Pair(entry: i, window: j, score: similarity(e.title, w.title)))
            }
        }
        pairs.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if entries[a.entry].order != entries[b.entry].order { return entries[a.entry].order < entries[b.entry].order }
            return a.window < b.window
        }
        var out: [Int: CGWindowID] = [:]
        var used = Set<Int>()
        for p in pairs where out[p.entry] == nil && !used.contains(p.window) {
            out[p.entry] = windows[p.window].id
            used.insert(p.window)
        }
        return out
    }

    /// The plans that put the live windows back. A window whose saved display is not connected
    /// keeps the display it is on, at the same fractions. Windows already in place are skipped.
    public static func plan(_ w: Workspace, windows: [TrackedWindow], displays: [Display],
                            grid: (Display) -> GridSpec) -> WorkspacePlan {
        let matched = match(w.windows, windows: windows)
        let resolved = resolve(w.displays, current: displays)
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var moves: [String: [PlannedMove]] = [:]
        var order: [String] = []
        for (i, entry) in w.windows.enumerated() {
            guard let id = matched[i], let live = byID[id] else { continue }
            guard let d = resolved[entry.display] ?? ScreenSpace.bestIndex(for: live.frame, among: displays.map(\.frame)).map({ displays[$0] })
            else { continue }
            let to = entry.frame.frame(in: d.usableFrame)
            if moves[d.id] == nil { order.append(d.id) }
            moves[d.id, default: []].append(PlannedMove(windowID: id, from: live.frame, to: to, cell: nil))
        }
        let plans: [ArrangePlan] = order.compactMap { id in
            guard let d = displays.first(where: { $0.id == id }) else { return nil }
            let m = moves[id, default: []].filter { !PlacementMath.approx($0.from, $0.to, 2) }
            guard !m.isEmpty else { return nil }
            return ArrangePlan(kind: .layout, displayID: id, usable: d.usableFrame, grid: grid(d), moves: m)
        }
        let unmatched = w.windows.indices.filter { matched[$0] == nil }
        return WorkspacePlan(plans: plans, matched: matched, unmatched: unmatched)
    }
}
