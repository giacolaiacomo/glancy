// Windows — workspaces on the tab: save the arrangement (every display), restore one (launching
// what is missing), the pane's state, and the layout commands the command bar runs on the display
// under the pointer. Restores and saves never happen on their own from here: the user clicks, a
// hotkey fires, the command bar runs one, or a display setup they opted into connects.

import AppKit

/// The pane's status line.
enum WorkspaceStatus: Equatable {
    case saved(name: String, windows: Int, displays: Int)
    case launching(name: String, apps: [String])
    case restored(RestoreOutcome)
    case deleted(name: String)
}

extension WindowsModel {

    // MARK: Pane

    func setWorkspaces(_ on: Bool) {
        guard on != showWorkspaces else { return }
        showWorkspaces = on
        if on {
            if showHelp { toggleHelp() }
            if showMore { showLayouts() }
        } else {
            cancelNaming()
            hoverWorkspace(nil)
        }
    }

    /// "Save current arrangement": the name field opens with the next "Workspace N".
    func beginSave() {
        guard restoringWorkspace == nil else { return }
        if !showWorkspaces { setWorkspaces(true) }
        renaming = nil
        naming = workspaces.nextDefaultName
    }

    func beginRename(_ id: UUID) {
        guard let w = workspaces.workspace(id) else { return }
        renaming = id
        naming = w.name
    }

    func cancelNaming() {
        naming = nil
        renaming = nil
    }

    /// ⏎ in the name field.
    func confirmNaming() {
        guard let text = naming else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = renaming {
            workspaces.rename(id, to: name)
        } else {
            saveWorkspace(named: name.isEmpty ? workspaces.nextDefaultName : name)
        }
        cancelNaming()
    }

    /// Captures every tileable window of every display. Returns nil when there is nothing to save.
    @discardableResult
    func saveWorkspace(named name: String? = nil) -> Workspace? {
        guard backend.isTrusted, backend.isRunning else { return nil }
        let displays = backend.displays()
        let captured = WorkspacePlanner.capture(name: String((name ?? workspaces.nextDefaultName).prefix(40)),
                                                windows: backend.allWindows(), displays: displays)
        guard !captured.windows.isEmpty else { return nil }
        let saved = workspaces.save(captured)
        setWorkspaceStatus(.saved(name: saved.name, windows: saved.windows.count, displays: saved.usedDisplays))
        return saved
    }

    func deleteWorkspace(_ id: UUID) {
        guard let w = workspaces.workspace(id) else { return }
        if workspaceHover == id { hoverWorkspace(nil) }
        workspaces.delete(id)
        setWorkspaceStatus(.deleted(name: w.name))
    }

    /// The pointer is on a workspace card (nil = left): its windows on the shown display are drawn
    /// on the real screen. Moves nothing.
    func hoverWorkspace(_ id: UUID?) {
        guard id != workspaceHover else { return }
        workspaceHover = id
        var plan: ArrangePlan?
        if let id, visible, trusted, let w = workspaces.workspace(id), let d = display {
            plan = WorkspaceRestorer.plan(w, backend).plans.first { $0.displayID == d.id }
        }
        if plan != workspacePreview { workspacePreview = plan }
        pushOverlay()
    }

    // MARK: Restore

    /// A card clicked (or a digit): restore, outcome on the status line.
    func restoreFromTab(_ id: UUID) {
        pending = Task { [weak self] in
            guard let self else { return }
            _ = await self.restoreWorkspace(id)
        }
    }

    /// Restores a workspace as one undoable operation. `launchMissing` off for the automatic
    /// display-connect apply. `onLaunching` hears the apps being opened (for a peek).
    @discardableResult
    func restoreWorkspace(_ id: UUID, launchMissing: Bool = true,
                          onLaunching: (([String]) -> Void)? = nil) async -> RestoreOutcome? {
        guard let w = workspaces.workspace(id) else { return nil }
        guard backend.isTrusted, backend.isRunning else {
            var o = RestoreOutcome(name: w.name)
            o.needsAccess = true
            return o
        }
        guard !busy, restoringWorkspace == nil else { return nil }
        busy = true
        restoringWorkspace = id
        hoverWorkspace(nil)
        let outcome = await restorer.restore(w, on: backend, launchMissing: launchMissing) { [weak self] apps in
            self?.setWorkspaceStatus(.launching(name: w.name, apps: apps), sticky: true)
            onLaunching?(apps)
        }
        busy = false
        restoringWorkspace = nil
        backendChanged()
        if visible { reloadMap(); recomputePreview() }
        setWorkspaceStatus(.restored(outcome))
        return outcome
    }

    /// The workspace "apply on connect" picks for these displays: the most recently saved one
    /// that opted in and was saved on this very setup.
    func workspaceForSetup(_ displays: [Display]) -> Workspace? {
        workspaces.workspaces.filter { $0.applyOnConnect && WorkspacePlanner.setupMatches($0, current: displays) }
            .max { $0.created < $1.created }
    }

    func setWorkspaceStatus(_ s: WorkspaceStatus, sticky: Bool = false) {
        workspaceStatus = s
        workspaceStatusTask?.cancel()
        workspaceStatusTask = nil
        guard !sticky else { return }
        let d = outcomeDuration + .seconds(1)
        workspaceStatusTask = Task { [weak self] in
            try? await Task.sleep(for: d)
            guard let self, !Task.isCancelled else { return }
            self.workspaceStatus = nil
        }
    }

    // MARK: Layout commands (command bar: the display under the pointer, at once)

    /// The frontmost `count` windows of the display under the pointer into a layout, the front one
    /// in the first cell. Returns the peek line.
    func layoutCommand(_ kind: WindowsAutoLayout.Kind, count: Int) async -> String {
        guard backend.isTrusted, backend.isRunning else { return WindowsText.t("Windows needs Accessibility") }
        guard !busy else { return WindowsText.t("Busy — try again") }
        let all = backend.displays()
        guard let d = ScopeRules.display(containing: pointer(), in: all) ?? all.first,
              let screen = backend.screenMap(for: nil, display: d) else { return WindowsText.t("Nothing to arrange here") }
        let windows = ScopeRules.list(screen.windows).prefix(count)
        guard !windows.isEmpty else { return WindowsText.t("Nothing to arrange here") }
        let shape = WindowsAutoLayout.shape(kind, count)
        let pws = windows.map { PlanWindow(id: $0.id, frame: $0.frame, bundleID: $0.bundleID, title: $0.title) }
        let plan = WindowsAutoLayout.plan(shape, windows: Array(pws), order: .given, displayID: d.id, usable: d.usableFrame,
                                          gaps: backend.grid(for: d))
        return await commitCommand(plan, title: WindowsText.layoutTitle(shape))
    }

    /// The front window centred on its display at its own size (shrunk to fit).
    func centerCommand() async -> String {
        guard backend.isTrusted, backend.isRunning else { return WindowsText.t("Windows needs Accessibility") }
        guard !busy else { return WindowsText.t("Busy — try again") }
        let all = backend.displays()
        guard let id = backend.targetWindowID, let w = backend.window(id),
              let i = ScreenSpace.bestIndex(for: w.frame, among: all.map(\.frame)) else { return WindowsText.t("No app in front") }
        let d = all[i]
        let plan = ArrangePlan(kind: .place, displayID: d.id, usable: d.usableFrame, grid: backend.grid(for: d),
                               moves: [PlannedMove(windowID: id, from: w.frame, to: Self.centred(w.frame, in: d.usableFrame), cell: nil)])
        return await commitCommand(plan, title: WindowsText.t("Center"))
    }

    nonisolated static func centred(_ frame: CGRect, in usable: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, usable.width), height: min(frame.height, usable.height))
        return CGRect(x: (usable.midX - size.width / 2).rounded(), y: (usable.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private func commitCommand(_ plan: ArrangePlan, title: String) async -> String {
        guard !plan.moves.allSatisfy({ PlacementMath.approx($0.from, $0.to, 2) }) else {
            return title + " · " + WindowsText.t("Already in place")
        }
        busy = true
        let results = await backend.commit(plan, label: title)
        busy = false
        backendChanged()
        if visible { reloadMap(); recomputePreview() }
        return title + " · " + OutcomeReport(results: results, name: name).line
    }
}
