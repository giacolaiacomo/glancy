import AppKit
import SwiftUI

/// Every live state a closed notch can show, one module at a time and all together, on demo data:
/// what `scripts/cpu-lab.sh` measures (`GLANCY_LAB_STATE=<name>`) and what the collapsed-cost tests
/// hold to their budget. A closed surface may change only on a legitimate tick (a countdown digit,
/// a lyric line: `busyShare`), never run a continuous animation, and a state with nothing changing
/// on screen lays out nothing at all.
@MainActor
enum CollapsedStates {
    /// What a state is put in through: the seeded modules, their hub, the surface context.
    struct Rig {
        let set: IsolatedModules.Set
        let hub: ActivityHub
        let context: SurfaceContext
        func module<T>(_ type: T.Type) -> T? { set.modules.compactMap { $0 as? T }.first }
    }

    struct Case {
        let name: String
        /// The modules enabled and started (nil = all of them).
        let modules: Set<ModuleID>?
        /// The share of 50 ms slots in which the closed surface may lay out: 0 = none at all (nothing
        /// on screen changes); a countdown in seconds touches ~1 slot in 20, a lyric line's 0.2 s
        /// fade ~4 slots every few seconds. A continuous animation touches every slot (1.0).
        var busyShare: Double = 0
        /// How long after `apply` the state is steady (a peek gone, a HUD expired).
        var settle: Double = 1.2
        /// Before the modules start (fixtures read at start).
        var prepare: (@MainActor (Rig) -> Void)? = nil
        /// After the modules started.
        var apply: (@MainActor (Rig) -> Void)? = nil
    }

    static func named(_ name: String) -> Case? { all.first { $0.name == name } }

    static let all: [Case] = agents + media + timer + devices + calendar + others + [
        Case(name: "all", modules: nil, settle: 3.5, apply: { r in
            r.module(ControlModule.self)?.prepareForRender(.awake)
            r.module(NotesModule.self)?.prepareForRender(.wing)
            r.module(PowerModule.self)?.showSamplePeek()
            r.module(HUDModule.self)?.showSample()
            r.context.updates = AppUpdates.sample(available: "9.9.9")
        }),
    ]

    // MARK: Agents (the wing is the same view for every agent)

    static func agentEvents(_ agent: AgentKind, waiting: Bool, now: Date = .now) -> [AgentEvent] {
        (1...3).flatMap { i -> [AgentEvent] in
            let sid = "cost-\(agent.rawValue)-\(i)", cwd = "/Users/demo/Projects/p\(i)"
            var e = [AgentEvent(ts: now.addingTimeInterval(-300), kind: .sessionStart, sessionID: sid, cwd: cwd, agent: agent),
                     AgentEvent(ts: now.addingTimeInterval(-290), kind: .userPromptSubmit, sessionID: sid, cwd: cwd, prompt: "Task \(i)", agent: agent),
                     AgentEvent(ts: now.addingTimeInterval(-5), kind: .postToolUse, sessionID: sid, cwd: cwd, toolName: "Edit", agent: agent)]
            if waiting, i == 1 {
                e.append(AgentEvent(ts: now.addingTimeInterval(-2), kind: .permissionRequest, sessionID: sid, cwd: cwd, toolName: "Bash", agent: agent))
            }
            return e
        }
    }

    private static func agentsCase(_ name: String, _ agent: AgentKind, waiting: Bool) -> Case {
        Case(name: name, modules: [.agents], apply: { r in
            guard let agents = r.module(AgentsModule.self) else { return }
            agents.model.apply(.events(agentEvents(agent, waiting: waiting), quiet: true), from: agent)
        })
    }

    static let agents: [Case] = [
        agentsCase("agents.claude.working", .claudeCode, waiting: false),
        agentsCase("agents.claude.waiting", .claudeCode, waiting: true),
        agentsCase("agents.codex.working", .codex, waiting: false),
        agentsCase("agents.opencode.waiting", .opencode, waiting: true),
        // A session asks for permission: the drop-down shows, then goes.
        Case(name: "agents.peek", modules: [.agents], settle: 6, apply: { r in
            guard let agents = r.module(AgentsModule.self) else { return }
            agents.model.apply(.events(agentEvents(.claudeCode, waiting: false), quiet: true), from: .claudeCode)
            let now = Date.now
            agents.model.apply(.events([AgentEvent(ts: now, kind: .permissionRequest, sessionID: "cost-claudeCode-2",
                                                   cwd: "/Users/demo/Projects/p2", toolName: "Bash")], quiet: false), from: .claudeCode)
        }),
    ]

    // MARK: Media (demo track playing, drawn artwork and its tint)

    static let media: [Case] = [
        Case(name: "media.playing", modules: [.media], settle: 2),
        Case(name: "media.lyricsWing", modules: [.media], busyShare: 0.4, settle: 2, prepare: { r in
            r.set.media.prepareForRender(.lyricsWing)
        }),
        Case(name: "media.peek", modules: [.media], settle: 4.5, apply: { r in
            Task { @MainActor in
                try? await Delay.sleep(for: .milliseconds(500))
                r.set.media.showPeek()
            }
        }),
    ]

    // MARK: Timer

    static let timer: [Case] = [
        // The demo Pomodoro, 7 minutes into a focus round: minutes, changed once a minute.
        Case(name: "timer.pomodoro", modules: [.timer]),
        Case(name: "timer.running", modules: [.timer], apply: { r in r.set.timer.start(minutes: 25) }),
        Case(name: "timer.paused", modules: [.timer], apply: { r in r.set.timer.start(minutes: 25); r.set.timer.pause() }),
        // The last minute counts down in seconds.
        Case(name: "timer.finishing", modules: [.timer], busyShare: 0.25, apply: { r in r.set.timer.start(minutes: 1) }),
    ]

    // MARK: HUD, devices, power, voice

    static let devices: [Case] = [
        Case(name: "hud.volume.gone", modules: [.hud], settle: 3, apply: { r in r.module(HUDModule.self)?.showSample() }),
        Case(name: "hud.micMuted", modules: [.hud], apply: { r in r.module(HUDModule.self)?.showMicSample(.mutedInUse) }),
        Case(name: "hud.inUse", modules: [.hud], apply: { r in r.module(HUDModule.self)?.showMicSample(.cameraInUse) }),
        Case(name: "power.charging", modules: [.power], settle: 5, apply: { r in r.set.power.showSample(.pluggedIn) }),
        Case(name: "power.airpods.peek", modules: [.power], settle: 4.5, apply: { r in r.set.power.showSamplePeek() }),
        Case(name: "power.low.peek", modules: [.power], settle: 4.5, apply: { r in r.set.power.showSampleAlert(.low(10)) }),
        // Recording: the elapsed time, refreshed once a second.
        Case(name: "voice.recording", modules: [.notes], busyShare: 0.25, apply: { r in r.module(NotesModule.self)?.prepareForRender(.wing) }),
    ]

    // MARK: Calendar

    private static func calendarEvent(in seconds: TimeInterval) -> CalendarEvent {
        let now = Date.now
        return CalendarEvent(id: "cost-1", title: "Design review", start: now.addingTimeInterval(seconds),
                             end: now.addingTimeInterval(seconds + 1800), calendarID: "demo-work",
                             color: CalendarRGB(r: 0.36, g: 0.55, b: 1.0),
                             link: MeetingLink.extract(url: URL(string: "https://zoom.us/j/5550100123"), location: nil, notes: nil))
    }

    static let calendar: [Case] = [
        // The demo call in 6 minutes: "in 6 min", changed once a minute.
        Case(name: "calendar.soon", modules: [.calendar]),
        // Under 2 minutes: a seconds countdown.
        Case(name: "calendar.imminent", modules: [.calendar], busyShare: 0.25, settle: 5.5, prepare: { r in
            r.set.calendar.eventList = [calendarEvent(in: 100)]
        }),
        Case(name: "calendar.started", modules: [.calendar], prepare: { r in
            r.set.calendar.eventList = [calendarEvent(in: -30)]
        }),
        Case(name: "calendar.overrun", modules: [.calendar], settle: 4, apply: { r in r.module(CalendarModule.self)?.prepareForRender(.overrun) }),
    ]

    // MARK: Notifications, shelf, control, monitor, updates

    static let others: [Case] = [
        Case(name: "notifications.peek", modules: [.notifications], settle: 5.5, apply: { r in
            r.module(NotificationsModule.self)?.showSamplePeek()
        }),
        // A drag over the notch: the wing the Shelf posts while files hover it.
        Case(name: "shelf.dragWing", modules: [.shelf], apply: { r in
            r.hub.post(LiveActivity(id: "shelf.drag", module: .shelf, priority: 95,
                                    left: AnyView(ShelfDragWing(count: 3)), right: AnyView(EmptyView())))
        }),
        Case(name: "shelf.screenshot.peek", modules: [.shelf], settle: 7.5, apply: { r in
            r.set.shelf.prepareForRender(.screenshotPeek, scratch: FileManager.default.temporaryDirectory
                .appendingPathComponent("glancy-cost-shelf-\(getpid())", isDirectory: true))
        }),
        Case(name: "control.awake", modules: [.control], apply: { r in r.module(ControlModule.self)?.prepareForRender(.awake) }),
        Case(name: "control.color.peek", modules: [.control], settle: 4, apply: { r in r.module(ControlModule.self)?.showSampleColorPeek() }),
        Case(name: "monitor", modules: [.monitor]),
        Case(name: "updates.available", modules: [.agents], apply: { r in
            r.context.updates = AppUpdates.sample(available: "9.9.9")
        }),
    ]
}
