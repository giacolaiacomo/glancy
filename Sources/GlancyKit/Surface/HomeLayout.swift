import SwiftUI

// Home's widgets: what each one is, the user's choice, mode and order (Settings → Home, kept in
// `AppSettings`), and how the cards share the page (pure, tested).

/// When a widget's card is on Home.
public enum HomeWidgetMode: String, CaseIterable, Codable, Sendable {
    /// Even at rest: with nothing going on the card shows its idle state (the last track and
    /// Play, quick timers, the battery…).
    case always
    /// Only while the module has something (playing, a timer running, a meeting coming up…).
    case whenNeeded

    var title: String {
        switch self {
        case .always: "Always"
        case .whenNeeded: "Only when needed"
        }
    }
}

/// A card Home can show. Most modules have one; Agents has two (the sessions and the plan limits).
public enum HomeWidget: String, CaseIterable, Codable, Sendable {
    case agents, limits, calendar, media, timer, notes, shelf, control, power, meetings

    /// The module that draws it (and whose being off hides it).
    public var module: ModuleID {
        switch self {
        case .agents, .limits: .agents
        case .calendar: .calendar
        case .media: .media
        case .timer: .timer
        case .notes: .notes
        case .shelf: .shelf
        case .control: .control
        case .power: .power
        case .meetings: .meetings
        }
    }

    /// The module's one card (Agents' sessions card for Agents).
    public init?(module: ModuleID) {
        guard let w = Self.allCases.first(where: { $0.module == module }) else { return nil }
        self = w
    }

    /// The order a new Home starts with: today's Home (sessions, meeting, media) with the plan
    /// limits right after the sessions.
    /// Meetings (opt-in) comes last: while it records or asks, its live priority puts it on Home anyway.
    public static let defaultOrder: [HomeWidget] = [.agents, .limits, .calendar, .media, .timer, .notes, .shelf, .control, .power, .meetings]

    /// Always for what is worth a look at rest (sessions, plan limits, the next meeting, the last
    /// track and Play, quick timers); Only when needed for the rest, which says nothing useful
    /// at rest (the battery at a normal level, an empty shelf, Keep awake off, no pinned note).
    public var defaultMode: HomeWidgetMode {
        switch self {
        case .agents, .limits, .calendar, .media, .timer: .always
        case .notes, .shelf, .control, .power, .meetings: .whenNeeded
        }
    }

    /// Media is a tall tile on the right; every other card is a wide row.
    var isTile: Bool { self == .media }

    var title: String {
        switch self {
        case .agents: "Sessions"
        case .limits: "Limits"
        case .calendar: "Next meeting"
        case .media: "Media"
        case .timer: "Timer"
        case .notes: "Pinned note"
        case .shelf: "Shelf"
        case .control: "Keep awake"
        case .power: "Battery"
        case .meetings: "Meeting recording"
        }
    }

    /// When the card is there in Only when needed.
    var when: String {
        switch self {
        case .agents: "While a session is live"
        case .limits: "When a limit is nearly used up"
        case .calendar: "When a meeting is coming up"
        case .media: "While something is playing"
        case .timer: "While a timer runs"
        case .notes: "When a note is pinned"
        case .shelf: "When files are on the shelf"
        case .control: "While Keep awake is on"
        case .power: "Charging, low battery, headphones"
        case .meetings: "While a meeting is offered, recorded or transcribed"
        }
    }

    /// What the card shows at rest in Always.
    var idle: String {
        switch self {
        case .agents: "At rest: no live sessions"
        case .limits: "At rest: the last readings, with resets"
        case .calendar: "At rest: nothing else today"
        case .media: "At rest: the last track, with Play"
        case .timer: "At rest: quick timers"
        case .notes: "At rest: the latest note"
        case .shelf: "At rest: a place to drop files"
        case .control: "At rest: a switch to turn it on"
        case .power: "At rest: the battery level"
        case .meetings: "At rest: the last recording, with Play"
        }
    }

    @MainActor var symbol: String {
        switch self {
        case .limits: "gauge.with.needle"
        case .control: "cup.and.saucer"
        default: SurfaceContext.symbol(module)
        }
    }
}

/// One card a module offers Home right now.
public struct HomeWidgetCard {
    public let widget: HomeWidget
    public let view: AnyView
    /// How urgent it is now (0 = the user's order decides); nil = the module's live priority.
    public var priority: Int?
    /// The widget's idle state (Always, nothing going on): it only fills the places the cards
    /// with something leave free.
    public var idle: Bool
    public init(_ widget: HomeWidget, _ view: AnyView, priority: Int? = nil, idle: Bool = false) {
        self.widget = widget; self.view = view; self.priority = priority; self.idle = idle
    }
}

/// How the chosen cards share the page. Pure.
enum HomeLayout {
    /// Columns left to right, each one card or two stacked; `tileLast`: the last column is the
    /// media tile (a fixed width), else the columns share the width evenly.
    struct Arrangement: Equatable {
        var columns: [[HomeWidget]]
        var tileLast: Bool
    }

    /// Without the media tile four cards fit (two columns of two); with it, two beside it.
    static func capacity(withTile: Bool) -> Int { withTile ? 3 : 4 }

    /// The cards that make it: the ones with something first, the most urgent of them first (a
    /// waiting agent, a meeting starting) then in the user's order; the idle ones (Always, at
    /// rest) fill the places left, in the user's order. Shown in the user's order.
    static func pick(_ available: [HomeWidget], idle: Set<HomeWidget> = [], order: [HomeWidget],
                     priority: (HomeWidget) -> Int) -> [HomeWidget] {
        func index(_ w: HomeWidget) -> Int { order.firstIndex(of: w) ?? order.count }
        let ranked = available.sorted { a, b in
            let ia = idle.contains(a), ib = idle.contains(b)
            if ia != ib { return !ia }
            let pa = ia ? 0 : priority(a), pb = ib ? 0 : priority(b)
            return pa != pb ? pa > pb : index(a) < index(b)
        }
        var chosen: [HomeWidget] = []
        for w in ranked {
            let withTile = chosen.contains(where: \.isTile) || w.isTile
            if chosen.count < capacity(withTile: withTile) { chosen.append(w) }
        }
        return chosen.sorted { index($0) < index($1) }
    }

    /// 1 card: the whole page. 2: stacked. 3: two stacked and one beside them. 4: two columns of
    /// two. The media tile always goes right, beside at most two stacked rows.
    static func arrange(_ shown: [HomeWidget]) -> Arrangement {
        let rows = shown.filter { !$0.isTile }
        if shown.contains(where: \.isTile) {
            return rows.isEmpty ? Arrangement(columns: [[.media]], tileLast: false)
                : Arrangement(columns: [Array(rows.prefix(2)), [.media]], tileLast: true)
        }
        switch rows.count {
        case 0: return Arrangement(columns: [], tileLast: false)
        case 1, 2: return Arrangement(columns: [rows], tileLast: false)
        default: return Arrangement(columns: [Array(rows.prefix(2)), Array(rows.dropFirst(2).prefix(2))], tileLast: false)
        }
    }

    /// The order with every widget once: the saved one, then any it doesn't know (new widgets)
    /// at their default place.
    static func normalized(_ saved: [HomeWidget]) -> [HomeWidget] {
        var out: [HomeWidget] = []
        for w in saved where !out.contains(w) { out.append(w) }
        for w in HomeWidget.defaultOrder where !out.contains(w) {
            // After the widget that precedes it by default, if any.
            let before = HomeWidget.defaultOrder.prefix { $0 != w }.last { out.contains($0) }
            if let before, let i = out.firstIndex(of: before) { out.insert(w, at: i + 1) } else { out.insert(w, at: 0) }
        }
        return out
    }
}
