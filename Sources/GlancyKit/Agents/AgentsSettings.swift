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
        VStack(alignment: .leading, spacing: 4.ui) {
            ForEach(module.availableSources, id: \.self) { kind in
                let status = module.sourceStatus(kind)
                SettingsRow(kind.name, note: status.line, noteColor: color(status.level)) {
                    HStack(spacing: 8.ui) {
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
            LimitsSettings(module: module, limits: module.limits)
                .padding(.top, 6.ui)
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

/// Settings → Agents → Plan limits: one switch per service (on by default only when its CLI or
/// folder is there), alerts, how old a reading may get before the tab refreshes it.
struct LimitsSettings: View {
    let module: AgentsModule
    @Bindable var limits: UsageLimitsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4.ui) {
            SettingsGroupTitle(LimitsText.t("Plan limits"))
            SettingsRow(LimitsText.t("Claude Code limits"), note: claudeNote.text, noteColor: claudeNote.warn ? Theme.waiting : Theme.tertiary) {
                NotchSwitch(isOn: $limits.claudeEnabled)
            }
            SettingsRow(LimitsText.t("Codex limits"), note: codexNote.text, noteColor: codexNote.warn ? Theme.waiting : Theme.tertiary) {
                NotchSwitch(isOn: $limits.codexEnabled)
            }
            SettingsRow(LimitsText.t("Limit alerts"),
                        note: LimitsText.t("A drop-down at 90% and 100%, when a session is on pace to run out, and when a used-up limit resets")) {
                NotchSwitch(isOn: $limits.alertsEnabled)
            }
            if limits.claudeEnabled {
                SettingsRow(LimitsText.t("Refresh after")) {
                    NotchSegments(selection: $limits.refreshMinutes,
                                  options: UsageLimitsStore.minuteChoices.map { ($0, "\($0) min") })
                }
            }
            SettingsNote(LimitsText.t("Safe by design: Glancy never reads tokens, cookies or passwords, never calls private endpoints and never sends a message. Claude's /usage runs only if the binary is signed by Anthropic, with no tools, MCP servers or hooks, sandboxed from your personal folders."))
        }
    }

    private var claudeNote: (text: String, warn: Bool) {
        switch limits.claudeStatus {
        case .notGenuine: return (LimitsText.t("Not signed by Anthropic: never run"), true)
        case .unexpectedOutput: return (LimitsText.t("Answered unexpectedly: stopped until turned off and on"), true)
        case .notInstalled: return (LimitsText.t("CLI not found"), true)
        default:
            if limits.fetcher != nil, limits.fetcher?.isInstalled == false { return (LimitsText.t("CLI not found"), true) }
            return (LimitsText.t("Runs the official /usage (0 tokens) when the tab opens, at most every 60 s"), false)
        }
    }

    private var codexNote: (text: String, warn: Bool) {
        if !limits.codexPresent() && limits.codex == nil { return (LimitsText.t("Not found: Codex has not run on this Mac yet"), true) }
        if module.availableSources.contains(.codex), !module.isSourceEnabled(.codex) { return (LimitsText.t("Needs Codex on in Sources above"), true) }
        return (LimitsText.t("From the rate_limits Codex writes in ~/.codex/sessions"), false)
    }
}
