// Windows — what the command bar can do here: auto-arrange, the layouts for the display under the
// pointer (halves, thirds, 2×2, left / right half, maximize, fill the empty space, center), undo,
// save a workspace, and restore each saved one. `results(for:)` answers a workspace's name,
// "layout 2x2" and "save workspace <name>". Everything runs at once and reports in a peek; undo
// with ⌃⌥Z.

import Foundation

extension WindowsModule {

    public func commands() -> [GlancyCommand] {
        WindowsText.register()
        var out: [GlancyCommand] = [
            command("autoArrange", "Auto-arrange windows", "rectangle.split.2x2",
                    subtitle: "The display under the pointer",
                    ["arrange", "tile", "auto", "windows", "disponi", "affianca", "automatico", "finestre"]) { m in
                m.autoArrange(appOnly: false)
            },
        ]
        for l in Self.layoutCommands {
            out.append(command("layout.\(l.id)", l.title, l.symbol, subtitle: l.subtitle, l.keywords) { m in m.runLayout(l.id) })
        }
        out.append(command("undo", "Undo the last window change", "arrow.uturn.backward",
                           ["undo", "revert", "windows", "annulla", "finestre"]) { m in m.undoFromCommand() })
        out.append(command("saveWorkspace", "Save workspace", "square.and.arrow.down",
                           subtitle: "Every window on every display",
                           ["workspace", "save", "arrangement", "salva", "disposizione", "finestre"]) { m in m.saveWorkspaceNow() })
        for w in workspaces.workspaces { out.append(restoreCommand(w, rank: 0)) }
        return out
    }

    public func results(for query: String) -> [GlancyCommand] {
        let q = Self.fold(query)
        guard q.count >= 2 else { return [] }
        var out: [GlancyCommand] = []
        // "save workspace Dev" / "salva workspace Dev"
        for prefix in ["save workspace ", "salva workspace ", "save as ", "salva come "] where q.hasPrefix(prefix) {
            let name = String(query.trimmingCharacters(in: .whitespaces).dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { break }
            WindowsText.register()
            out.append(GlancyCommand(id: "windows.saveWorkspace.named", module: .windows,
                                     title: WindowsText.f("Save workspace “%@”", name),
                                     subtitle: WindowsText.t("Every window on every display"), symbol: "square.and.arrow.down",
                                     rank: 90) { [weak self] in self?.saveWorkspaceNow(named: name) })
            return out
        }
        // A workspace by name ("dev", "restore dev", "workspace dev").
        var name = q
        for prefix in ["restore ", "ripristina ", "workspace ", "apply ", "applica "] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if !name.isEmpty {
            for w in workspaces.workspaces {
                let n = Self.fold(w.name)
                if n.hasPrefix(name) { out.append(restoreCommand(w, rank: n == name ? 95 : 85)) }
                else if name.count >= 3, n.contains(name) { out.append(restoreCommand(w, rank: 70)) }
            }
        }
        // "layout 2x2", "griglia 2x2", "halves", "metà".
        var rest = q
        var explicit = false
        for prefix in ["layout ", "disposizione ", "griglia ", "grid "] where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count)); explicit = true
        }
        rest = rest.replacingOccurrences(of: "×", with: "x")
        if !rest.isEmpty {
            for l in Self.layoutCommands {
                let hit = l.aliases.contains(rest) || (rest.count >= 3 && l.aliases.contains { $0.hasPrefix(rest) })
                guard hit else { continue }
                out.append(command("layout.\(l.id)", l.title, l.symbol, subtitle: l.subtitle, l.keywords,
                                   rank: explicit || l.aliases.contains(rest) ? 75 : 60) { m in m.runLayout(l.id) })
            }
        }
        return out
    }

    // MARK: Layouts

    struct LayoutCommand {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let keywords: [String]
        /// What `results(for:)` answers ("2x2" after "layout ").
        let aliases: [String]
    }

    static let layoutCommands: [LayoutCommand] = [
        LayoutCommand(id: "halves", title: "Halves", subtitle: "The two front windows side by side", symbol: "rectangle.split.2x1",
                      keywords: ["layout", "halves", "split", "side by side", "two", "metà", "affiancate", "due"],
                      aliases: ["halves", "half", "split", "2x1", "side by side", "meta", "affiancate"]),
        LayoutCommand(id: "thirds", title: "Thirds", subtitle: "The three front windows in columns", symbol: "rectangle.split.3x1",
                      keywords: ["layout", "thirds", "columns", "three", "terzi", "colonne", "tre"],
                      aliases: ["thirds", "third", "3x1", "columns", "terzi", "colonne"]),
        LayoutCommand(id: "grid", title: "2×2 grid", subtitle: "The four front windows in a grid", symbol: "square.grid.2x2",
                      keywords: ["layout", "grid", "2x2", "four", "quarters", "griglia", "quattro"],
                      aliases: ["2x2", "grid", "quarters", "griglia", "quarti"]),
        LayoutCommand(id: "left", title: "Left half", subtitle: "The front window", symbol: "rectangle.lefthalf.filled",
                      keywords: ["left", "half", "sinistra", "metà"], aliases: ["left", "left half", "sinistra"]),
        LayoutCommand(id: "right", title: "Right half", subtitle: "The front window", symbol: "rectangle.righthalf.filled",
                      keywords: ["right", "half", "destra", "metà"], aliases: ["right", "right half", "destra"]),
        LayoutCommand(id: "maximize", title: "Maximize", subtitle: "The front window", symbol: "arrow.up.left.and.arrow.down.right",
                      keywords: ["maximize", "maximise", "full", "massimizza", "intero"],
                      aliases: ["maximize", "maximise", "max", "full", "massimizza"]),
        LayoutCommand(id: "fill", title: "Fill the empty space", subtitle: "The front window, where no other window is",
                      symbol: "rectangle.dashed",
                      keywords: ["fill", "empty", "free", "space", "gap", "hole", "riempi", "vuoto", "libero", "spazio"],
                      aliases: ["fill", "fill empty space", "fill space", "empty space", "free space", "riempi", "spazio vuoto",
                                "spazio libero"]),
        LayoutCommand(id: "center", title: "Center", subtitle: "The front window, at its size", symbol: "rectangle.center.inset.filled",
                      keywords: ["center", "centre", "middle", "centra", "centro"], aliases: ["center", "centre", "centra", "centro"]),
    ]

    func runLayout(_ id: String) {
        switch id {
        case "left": direct(.leftHalf)
        case "right": direct(.rightHalf)
        case "maximize": direct(.maximize)
        default:
            Task { [weak self] in
                guard let self else { return }
                let line: String
                switch id {
                case "halves": line = await self.model.layoutCommand(.sideBySide, count: 2)
                case "thirds": line = await self.model.layoutCommand(.columns, count: 3)
                case "grid": line = await self.model.layoutCommand(.grid, count: 4)
                case "fill": line = await self.model.fillCommand()
                default: line = await self.model.centerCommand()
                }
                self.peek(line)
            }
        }
    }

    func undoFromCommand() {
        guard model.backend.canUndo else { peek(WindowsText.t("Nothing to undo")); return }
        Task { [weak self] in
            guard let self else { return }
            let line = await self.model.direct(.undo)
            self.peek(line ?? WindowsText.t("Undone"))
        }
    }

    // MARK: Helpers

    private func restoreCommand(_ w: Workspace, rank: Int) -> GlancyCommand {
        let id = w.id
        let displays = w.usedDisplays
        let sub = (w.windows.count == 1 ? WindowsText.t("1 window") : WindowsText.f("%d windows", w.windows.count))
            + (displays > 1 ? " · " + WindowsText.f("%d displays", displays) : "")
            + (w.hotkey.modifiers != 0 ? " · " + w.hotkey.description : "")
        return GlancyCommand(id: "windows.workspace.\(id.uuidString)", module: .windows,
                             title: WindowsText.f("Restore %@", w.name), subtitle: sub, symbol: "square.stack.3d.up",
                             keywords: [w.name, "workspace", "restore", "ripristina", "spazio di lavoro"], rank: rank) { [weak self] in
            self?.restoreWorkspace(id)
        }
    }

    private func command(_ id: String, _ title: String, _ symbol: String, subtitle: String? = nil, _ keywords: [String],
                         rank: Int = 0, run: @escaping @MainActor (WindowsModule) -> Void) -> GlancyCommand {
        GlancyCommand(id: "windows.\(id)", module: .windows, title: WindowsText.t(title), subtitle: subtitle.map(WindowsText.t),
                      symbol: symbol, keywords: keywords, rank: rank) { [weak self] in
            guard let self else { return }
            run(self)
        }
    }

    /// Lowercased, accents off, single spaces.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
