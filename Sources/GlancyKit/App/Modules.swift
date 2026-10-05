/// The module registry. The lead adds each wave's modules to `make()`; order here does not matter
/// (the panel orders tabs per SPEC §2).
@MainActor
public enum Modules {
    /// The real modules. Constructing them must be cheap: all work begins in `start(hub:)`.
    public static func make() -> [any GlancyModule] {
        let agents = AgentsModule()
        let windows = WindowsModule()
        // Agents ↔ Windows link: ⌥-click tiles a session's terminal, "Lay out sessions" arranges
        // them all (previewed, undoable). Weak: turning Windows off just hides those actions.
        agents.tiling = windows
        return [agents, CalendarModule(), MediaModule(), TimerModule(), ShelfModule(), ClipboardModule(), windows, HUDModule(), PowerModule(), NotificationsModule(),
                NotesModule()]
    }

    /// The real modules, plus the demo ones when launched with `--demo` (never overriding a real
    /// module with the same id).
    public static func make(demo: Bool) -> [any GlancyModule] {
        var list = make()
        if demo {
            list += DemoModule.suite().filter { d in !list.contains { $0.id == d.id } }
        }
        return list
    }
}

/// The Windows module is the Agents module's tiler (Agents/AgentsTiling.swift).
extension WindowsModule: AgentsTiling {}
