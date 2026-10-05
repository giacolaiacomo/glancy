// Windows — the saved workspaces, persisted to workspaces.json (nil URL = in memory: tests, the
// renderer). Every change is written at once, atomically; nothing is read again until next launch.

import Foundation
import Observation

@MainActor @Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace]
    @ObservationIgnored private let url: URL?
    /// Called after every change (the module re-registers the workspace hotkeys).
    @ObservationIgnored var onChange: (() -> Void)?

    init(url: URL?, workspaces: [Workspace]? = nil) {
        self.url = url
        self.workspaces = workspaces ?? url.map { WorkspaceFile.load(from: $0).workspaces } ?? []
    }

    func workspace(_ id: UUID) -> Workspace? { workspaces.first { $0.id == id } }

    /// The next free "Workspace N".
    var nextDefaultName: String {
        WorkspacePlanner.defaultName(existing: workspaces.map(\.name)) { WindowsText.f("Workspace %d", $0) }
    }

    func add(_ w: Workspace) {
        workspaces.append(w)
        changed()
    }

    /// Same name as an existing one (case-insensitive): that one is replaced, keeping its id,
    /// hotkey and "apply on connect".
    @discardableResult
    func save(_ w: Workspace) -> Workspace {
        if let i = workspaces.firstIndex(where: { $0.name.compare(w.name, options: .caseInsensitive) == .orderedSame }) {
            var replaced = w
            replaced.id = workspaces[i].id
            replaced.hotkey = workspaces[i].hotkey
            replaced.applyOnConnect = workspaces[i].applyOnConnect
            workspaces[i] = replaced
            changed()
            return replaced
        }
        add(w)
        return w
    }

    func update(_ id: UUID, _ body: (inout Workspace) -> Void) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        var w = workspaces[i]
        body(&w)
        guard w != workspaces[i] else { return }
        workspaces[i] = w
        changed()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = String(trimmed.prefix(40)) }
    }

    func delete(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        workspaces.removeAll { $0.id == id }
        changed()
    }

    /// The renderer and tests: replace everything without touching disk.
    func replaceAll(_ list: [Workspace]) {
        workspaces = list
        onChange?()
    }

    private func changed() {
        if let url { try? WorkspaceFile(workspaces: workspaces).save(to: url) }
        onChange?()
    }
}
