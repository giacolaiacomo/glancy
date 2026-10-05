import AppKit
import SwiftUI

/// Settings → Agents: one row per source with its switch and a status line ("Claude Code: hook
/// found", "Codex: reading ~/.codex/sessions", "OpenCode: install the plugin…"). The OpenCode
/// plugin is written to the user's config only when Install is clicked; Uninstall removes it.
struct AgentsSettingsSection: View {
    let module: AgentsModule
    /// Re-reads statuses after a switch or an install (they are computed on demand, not observed).
    @State private var tick = 0
    @State private var installNote: String?

    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 4) {
            ForEach(module.availableSources, id: \.self) { kind in
                let status = module.sourceStatus(kind)
                SettingsRow(kind.name, note: status.line, noteColor: color(status.level)) {
                    HStack(spacing: 8) {
                        if kind == .opencode, module.isSourceEnabled(kind), let installer = module.openCodeInstaller {
                            pluginButton(installer)
                        }
                        if kind == .claudeCode, module.isSourceEnabled(kind),
                           FileManager.default.fileExists(atPath: AgentsModule.defaultLogURL.path) {
                            NotchTextButton(AgentsText.t("Show log")) {
                                NSWorkspace.shared.activateFileViewerSelecting([AgentsModule.defaultLogURL])
                            }
                        }
                        NotchSwitch(isOn: Binding(get: { module.isSourceEnabled(kind) },
                                                  set: { module.setSource(kind, enabled: $0); tick += 1 }))
                    }
                }
            }
            if let installNote {
                SettingsNote(installNote)
            }
            SettingsNote(AgentsText.t("Read-only: Glancy never writes to Claude Code or Codex files. A session goes idle after 30 min without events; sessions silent for 12 h are dropped."))
        }
    }

    @ViewBuilder
    private func pluginButton(_ installer: OpenCodePluginInstaller) -> some View {
        if installer.isInstalled {
            if installer.isOutdated {
                NotchTextButton(AgentsText.t("Update")) { run { _ = try installer.install() } }
            }
            NotchTextButton(AgentsText.t("Uninstall")) { run { try installer.uninstall() } }
                .help(installer.pluginURL.path)
        } else {
            NotchTextButton(AgentsText.t("Install…")) {
                run {
                    let backup = try installer.install()
                    installNote = AgentsText.installed(installer.pluginURL.path, backup: backup?.lastPathComponent)
                }
            }
            .help(AgentsText.t("Adds Glancy's plugin to ~/.config/opencode/plugins (opencode.json is not touched). Restart OpenCode to load it."))
        }
    }

    private func run(_ body: () throws -> Void) {
        do {
            installNote = nil
            try body()
        } catch {
            installNote = AgentsText.t("Could not write the plugin file.") + " " + String(describing: error)
        }
        tick += 1
    }

    private func color(_ level: AgentSourceStatus.Level) -> Color {
        switch level {
        case .ok: Theme.tertiary
        case .off: Theme.tertiary
        case .missing: Theme.waiting
        }
    }
}

extension AgentsModule {
    /// The Settings index line: which sources are on and found.
    public var settingsSummary: String {
        let on = availableSources.filter { isSourceEnabled($0) && sourceStatus($0).level == .ok }
        switch on.count {
        case 0: return AgentsText.t("No agents found")
        case 1: return on[0].name
        default: return AgentsText.isItalian ? "\(on.count) agenti" : "\(on.count) agents"
        }
    }

    /// Settings → Agents, for `ModuleSections`.
    public func settingsSection() -> AnyView { AnyView(AgentsSettingsSection(module: self)) }
}
