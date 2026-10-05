import Foundation

// Pure logic of the Control module: tiles, keep-awake durations and state, colour hex, command-bar
// query parsing. No AppKit, no system calls: everything here is unit-tested.

// MARK: - Tiles

/// Every tile the Control tab can show. Toggles sit in the top row, one-shot tools below.
public enum ControlTile: String, CaseIterable, Codable, Sendable {
    // Toggles
    case keepAwake, darkMode, wifi, desktopIcons, hiddenFiles
    // Tools
    case lock, displaySleep, screenSaver, screenshot, colorPicker, mirror, emptyTrash, eject

    public var isToggle: Bool {
        switch self {
        case .keepAwake, .darkMode, .wifi, .desktopIcons, .hiddenFiles: true
        default: false
        }
    }

    static let toggles: [ControlTile] = allCases.filter(\.isToggle)
    static let tools: [ControlTile] = allCases.filter { !$0.isToggle }

    var symbol: String {
        switch self {
        case .keepAwake: "cup.and.saucer.fill"
        case .darkMode: "circle.lefthalf.filled"
        case .wifi: "wifi"
        case .desktopIcons: "menubar.dock.rectangle"
        case .hiddenFiles: "eye"
        case .lock: "lock.fill"
        case .displaySleep: "moon.zzz.fill"
        case .screenSaver: "sparkles.tv"
        case .screenshot: "camera.viewfinder"
        case .colorPicker: "eyedropper"
        case .mirror: "person.crop.square"
        case .emptyTrash: "trash"
        case .eject: "eject.fill"
        }
    }

    /// The name on the tile itself, where room is short.
    var shortTitle: String { self == .desktopIcons ? "Desktop" : title }

    /// English title (the key of the Italian table).
    var title: String {
        switch self {
        case .keepAwake: "Keep awake"
        case .darkMode: "Dark mode"
        case .wifi: "Wi-Fi"
        case .desktopIcons: "Desktop icons"
        case .hiddenFiles: "Hidden files"
        case .lock: "Lock"
        case .displaySleep: "Display off"
        case .screenSaver: "Screen saver"
        case .screenshot: "Screenshot"
        case .colorPicker: "Color picker"
        case .mirror: "Mirror"
        case .emptyTrash: "Empty Trash"
        case .eject: "Eject all"
        }
    }
}

/// Which tiles show and in what order (Settings → Control). Order is kept per group: toggles and
/// tools each keep their own row.
public struct ControlLayout: Codable, Equatable, Sendable {
    public var order: [ControlTile]
    public var hidden: Set<ControlTile>

    public init(order: [ControlTile] = ControlTile.allCases, hidden: Set<ControlTile> = []) {
        self.order = order; self.hidden = hidden
        normalize()
    }

    /// Every tile exactly once (tiles added in a later version join at the end of their group).
    public mutating func normalize() {
        var seen = Set<ControlTile>()
        order = order.filter { seen.insert($0).inserted }
        order += ControlTile.allCases.filter { !seen.contains($0) }
    }

    public var toggles: [ControlTile] { order.filter { $0.isToggle && !hidden.contains($0) } }
    public var tools: [ControlTile] { order.filter { !$0.isToggle && !hidden.contains($0) } }

    /// Moves a tile one step left (-1) or right (+1) inside its own group.
    public mutating func move(_ tile: ControlTile, by step: Int) {
        let group = order.filter { $0.isToggle == tile.isToggle }
        guard let i = group.firstIndex(of: tile) else { return }
        let j = i + step
        guard group.indices.contains(j) else { return }
        let other = group[j]
        guard let a = order.firstIndex(of: tile), let b = order.firstIndex(of: other) else { return }
        order.swapAt(a, b)
    }

    public func canMove(_ tile: ControlTile, by step: Int) -> Bool {
        let group = order.filter { $0.isToggle == tile.isToggle }
        guard let i = group.firstIndex(of: tile) else { return false }
        return group.indices.contains(i + step)
    }
}

// MARK: - Keep awake

public enum AwakeDuration: String, CaseIterable, Codable, Sendable {
    case m30, h1, h2, forever

    public var seconds: TimeInterval? {
        switch self {
        case .m30: 30 * 60
        case .h1: 3600
        case .h2: 7200
        case .forever: nil
        }
    }

    public var label: String {
        switch self {
        case .m30: "30m"
        case .h1: "1h"
        case .h2: "2h"
        case .forever: "∞"
        }
    }

    /// The next choice when the duration chip is clicked.
    public var next: AwakeDuration {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// The keep-awake state: on with an end (or none: until turned off).
public struct AwakeState: Equatable, Sendable {
    public var isOn = false
    public var started: Date?
    public var until: Date?
    /// The chosen length while on (or `.forever`); a custom command-bar length has none.
    public var duration: AwakeDuration?

    public init() {}

    public static func on(now: Date, seconds: TimeInterval?, duration: AwakeDuration?) -> AwakeState {
        var s = AwakeState()
        s.isOn = true
        s.started = now
        s.until = seconds.map { now.addingTimeInterval($0) }
        s.duration = duration
        return s
    }

    /// True when the end has passed.
    public func expired(now: Date) -> Bool {
        guard isOn, let until else { return false }
        return now >= until
    }
}

// MARK: - Colour

/// An sRGB colour as 0…255 components.
public struct RGB: Equatable, Hashable, Codable, Sendable {
    public var r: Int, g: Int, b: Int
    public init(r: Int, g: Int, b: Int) {
        self.r = min(max(r, 0), 255); self.g = min(max(g, 0), 255); self.b = min(max(b, 0), 255)
    }
    public init(red: Double, green: Double, blue: Double) {
        self.init(r: Int((red * 255).rounded()), g: Int((green * 255).rounded()), b: Int((blue * 255).rounded()))
    }

    /// "#FF8800".
    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    public var rgbString: String { "rgb(\(r), \(g), \(b))" }

    /// Perceived lightness 0…1, to pick ink over a swatch.
    public var luminance: Double { (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255 }

    /// Parses "#ff8800", "ff8800", "#f80", "0xFF8800", "hex ff8800", "rgb(255, 136, 0)", "255 136 0"
    /// is not accepted (too ambiguous). With `requirePrefix` a bare "ff8800" is rejected.
    public static func parse(_ text: String, requirePrefix: Bool = false) -> RGB? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("rgb(") || s.hasPrefix("rgb ") { return parseRGB(s) }
        var prefixed = false
        for p in ["hex ", "colore ", "color ", "colour "] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces); prefixed = true
        }
        if s.hasPrefix("#") { s.removeFirst(); prefixed = true } else if s.hasPrefix("0x") { s.removeFirst(2); prefixed = true }
        if requirePrefix, !prefixed { return nil }
        guard s.count == 3 || s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let v = Int(s, radix: 16) else { return nil }
        return RGB(r: (v >> 16) & 0xFF, g: (v >> 8) & 0xFF, b: v & 0xFF)
    }

    private static func parseRGB(_ s: String) -> RGB? {
        let body = s.dropFirst(4).replacingOccurrences(of: ")", with: "")
        let parts = body.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return RGB(r: parts[0], g: parts[1], b: parts[2])
    }
}

/// The last picked colours, newest first, without duplicates.
public struct RecentColors: Codable, Equatable, Sendable {
    public static let limit = 8
    public private(set) var colors: [RGB] = []
    public init(_ colors: [RGB] = []) { self.colors = Array(colors.prefix(Self.limit)) }

    public mutating func add(_ c: RGB) {
        colors.removeAll { $0 == c }
        colors.insert(c, at: 0)
        if colors.count > Self.limit { colors.removeLast(colors.count - Self.limit) }
    }

    public mutating func clear() { colors = [] }
}

// MARK: - Command bar queries

enum ControlQuery {
    /// Words that ask for keep-awake, EN + IT.
    static let awakeWords = ["awake", "caffeinate", "caffeine", "keep awake", "tieni sveglio", "sveglio", "sveglia", "caffè", "caffe", "amphetamine", "no sleep"]

    /// "awake 2h", "caffeinate 30m", "tieni sveglio 1 ora", "sveglio 90 min", "awake 1h30",
    /// "awake forever" / "sempre". Returns the seconds (nil = no end) or nothing when the query
    /// isn't a keep-awake request with a length.
    static func awake(_ query: String) -> TimeInterval?? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard let word = awakeWords.sorted(by: { $0.count > $1.count }).first(where: { q.hasPrefix($0) }) else { return nil }
        let rest = q.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        if ["forever", "always", "sempre", "∞", "per sempre", "indefinitely"].contains(rest) { return .some(nil) }
        guard let secs = duration(rest), secs > 0 else { return nil }
        return .some(secs)
    }

    /// "2h", "30m", "1h30", "1h 30m", "90 min", "2 ore", "1 ora", "45 minuti", "3 hours".
    static func duration(_ text: String) -> TimeInterval? {
        let s = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        var total: TimeInterval = 0
        var number = ""
        var i = s.startIndex
        var sawUnit = false
        while i < s.endIndex {
            let c = s[i]
            if c.isNumber || c == "." || c == "," {
                number.append(c == "," ? "." : c)
                i = s.index(after: i)
                continue
            }
            var unit = ""
            while i < s.endIndex, s[i].isLetter { unit.append(s[i]); i = s.index(after: i) }
            guard let n = Double(number), !unit.isEmpty else { return nil }
            switch unit {
            case "h", "hr", "hrs", "hour", "hours", "ora", "ore": total += n * 3600
            case "m", "min", "mins", "minute", "minutes", "minuto", "minuti": total += n * 60
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        if !number.isEmpty {
            // "1h30": a trailing number after a unit is minutes; a bare number alone is ambiguous.
            guard sawUnit, let n = Double(number) else { return nil }
            total += n * 60
        }
        return total > 0 && total <= 7 * 24 * 3600 ? total : nil
    }

    /// The colour asked for: "#ff8800", "hex ff8800", "0xff8800", "rgb(255,136,0)".
    static func color(_ query: String) -> RGB? { RGB.parse(query, requirePrefix: true) }
}

// MARK: - Formatting

enum ControlFormat {
    /// "1.2 GB", "340 MB".
    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: b)
    }

    /// "1.2 MB/s", "34 KB/s", "0 KB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        if b >= 1_000_000_000 { return String(format: "%.1f GB/s", b / 1_000_000_000) }
        if b >= 1_000_000 { return String(format: b >= 10_000_000 ? "%.0f MB/s" : "%.1f MB/s", b / 1_000_000) }
        return String(format: "%.0f KB/s", b / 1000)
    }

    /// "3d 4h", "5h 12m", "12m".
    static func uptime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(mm)m" }
        return "\(mm)m"
    }

    /// "1h 30m", "45m", "2h".
    static func length(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        let h = m / 60, mm = m % 60
        if h > 0 { return mm > 0 ? "\(h)h \(mm)m" : "\(h)h" }
        return "\(mm)m"
    }
}
