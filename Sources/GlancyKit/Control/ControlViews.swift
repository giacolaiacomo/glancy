import SwiftUI

// The Control tab: a row of toggle tiles, the tools below (or a question / the colour just picked /
// the camera mirror in their place), and the system stats on the right.

private enum Metrics {
    static var statsWidth: CGFloat { 160.ui }
    static var toggleHeight: CGFloat { 68.ui }
    static var toolHeight: CGFloat { 30.ui }
    static var gap: CGFloat { 6.ui }
    static var radius: CGFloat { 12.ui }
}

private struct Caption: View {
    let text: String
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 9.5.ui, weight: .semibold)).tracking(0.6.ui)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
    }
}

struct ControlTabView: View {
    let module: ControlModule
    let model: ControlModel
    let settings: ControlSettings
    let stats: StatsSampler

    var body: some View {
        HStack(alignment: .top, spacing: 10.ui) {
            Group {
                if model.mirror != .off {
                    MirrorPanel(module: module, live: model.mirror == .live)
                } else {
                    VStack(spacing: 8.ui) {
                        TogglesRow(module: module, model: model, tiles: settings.layout.toggles, awakeDefault: settings.awakeDefault)
                        lower
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if settings.showStats {
                StatsCard(stats: stats.snapshot)
                    .frame(width: Metrics.statsWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    @ViewBuilder private var lower: some View {
        if let prompt = model.prompt {
            PromptBar(module: module, prompt: prompt)
        } else if let color = model.picked {
            ColorBar(module: module, color: color, recent: model.recent.colors)
        } else {
            ToolsGrid(module: module, model: model, tiles: settings.layout.tools, wide: !settings.showStats)
        }
    }
}

// MARK: - Toggles

private struct TogglesRow: View {
    let module: ControlModule
    let model: ControlModel
    let tiles: [ControlTile]
    let awakeDefault: AwakeDuration

    var body: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(tiles, id: \.self) { tile in
                ToggleTile(tile: tile, on: model.isOn(tile), busy: model.busy.contains(tile),
                           state: state(tile), enabled: tile != .wifi || model.wifi != nil,
                           accent: tile == .keepAwake ? Theme.waiting : Theme.primary,
                           chip: tile == .keepAwake ? chip : nil,
                           action: { module.toggle(tile) },
                           chipAction: { module.cycleAwakeDuration() })
            }
        }
        .frame(height: Metrics.toggleHeight)
    }

    private var chip: String {
        model.awake.isOn ? (model.awake.duration ?? .forever).label : awakeDefault.label
    }

    private func state(_ tile: ControlTile) -> String {
        switch tile {
        case .keepAwake:
            guard model.awake.isOn else { return ControlText.t("Off") }
            return model.awake.until.map { ControlText.time($0) }.map { "→ " + $0 } ?? "∞"
        case .darkMode: return model.darkMode ? ControlText.t("Dark") : ControlText.t("Light")
        case .wifi:
            guard let on = model.wifi else { return ControlText.t("No Wi-Fi") }
            return on ? ControlText.t("On") : ControlText.t("Off")
        case .desktopIcons: return model.desktopIconsHidden ? ControlText.t("Icons hidden") : ControlText.t("Icons shown")
        case .hiddenFiles: return model.hiddenFilesShown ? ControlText.t("Shown") : ControlText.t("Hidden")
        default: return ""
        }
    }
}

private struct ToggleTile: View {
    let tile: ControlTile
    let on: Bool
    let busy: Bool
    let state: String
    let enabled: Bool
    let accent: Color
    let chip: String?
    let action: () -> Void
    let chipAction: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle().fill(on ? accent : Color.white.opacity(0.10))
                        if busy {
                            ProgressView().controlSize(.mini).tint(on ? .black : Theme.secondary)
                        } else {
                            // Palette with one ink for every layer: the variable Wi-Fi glyph
                            // otherwise draws its arcs in a light layer colour on the white disc.
                            let ink = on ? Color.black.opacity(0.85) : Theme.secondary
                            Text(Image(systemName: symbol))
                                .font(.system(size: 11.ui, weight: .semibold))
                                .foregroundStyle(ink)
                        }
                    }
                    .frame(width: 24.ui, height: 24.ui)
                    Spacer(minLength: 0)
                    if let chip {
                        Button(action: chipAction) {
                            Text(verbatim: chip)
                                .font(.system(size: 9.5.ui, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(on ? Theme.waiting : Theme.secondary)
                                .padding(.horizontal, 5.ui)
                                .frame(height: 16.ui)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(ControlText.t("Length"))
                    }
                }
                Spacer(minLength: 2.ui)
                Text(verbatim: ControlText.t(tile.shortTitle))
                    .font(Theme.font(.s, .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1).minimumScaleFactor(0.85).allowsTightening(true)
                Text(verbatim: state)
                    .font(Theme.font(.xs)).monospacedDigit()
                    .foregroundStyle(on && tile == .keepAwake ? Theme.waiting : Theme.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(8.ui)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .fill(Color.white.opacity(on ? 0.12 : hover ? 0.09 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .help(ControlText.t(tile.title))
        .accessibilityLabel(ControlText.t(tile.title) + ", " + state)
    }

    private var symbol: String {
        switch tile {
        case .darkMode: on ? "moon.fill" : "sun.max.fill"
        case .wifi: on ? "wifi" : "wifi.slash"
        case .desktopIcons: on ? "eye.slash" : "menubar.dock.rectangle"
        case .hiddenFiles: on ? "eye" : "eye.slash"
        default: tile.symbol
        }
    }
}

// MARK: - Tools

private struct ToolsGrid: View {
    let module: ControlModule
    let model: ControlModel
    let tiles: [ControlTile]
    let wide: Bool

    var body: some View {
        let perRow = wide ? 5 : 4
        let rows = stride(from: 0, to: tiles.count, by: perRow).map { Array(tiles[$0..<min($0 + perRow, tiles.count)]) }
        VStack(spacing: Metrics.gap) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: Metrics.gap) {
                    ForEach(rows[r], id: \.self) { tile in
                        ToolPill(tile: tile, busy: model.busy.contains(tile), on: model.isOn(tile),
                                 enabled: tile != .eject || !model.ejectable.isEmpty) { module.run(tile) }
                    }
                    // Keep the last row's pills the same width as the others.
                    ForEach(0..<(perRow - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
                .frame(minHeight: Metrics.toolHeight, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ToolPill: View {
    let tile: ControlTile
    let busy: Bool
    let on: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5.ui) {
                ZStack {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: tile.symbol)
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 10.5.ui, weight: .semibold))
                            .foregroundStyle(hover ? Theme.primary : Theme.secondary)
                    }
                }
                .frame(width: 14.ui)
                Text(verbatim: ControlText.t(tile.title))
                    .font(Theme.font(.s, .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1).minimumScaleFactor(0.85).allowsTightening(true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7.ui)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 9.ui, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.11 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 9.ui, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled || busy)
        .help(ControlText.t(tile.title))
        .accessibilityLabel(ControlText.t(tile.title))
    }
}

// MARK: - Prompt bar

private struct PromptBar: View {
    let module: ControlModule
    let prompt: ControlPrompt

    var body: some View {
        HStack(spacing: 10.ui) {
            Image(systemName: symbol)
                .font(.system(size: 14.ui, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30.ui, height: 30.ui)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2.ui) {
                Text(verbatim: title).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(2)
                if let detail {
                    Text(verbatim: detail).font(Theme.font(.xs)).foregroundStyle(Theme.tertiary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6.ui)
            if let confirm {
                if isQuestion { NotchTextButton(ControlText.t("Cancel")) { module.dismissPrompt() } }
                Button { module.confirm() } label: {
                    Text(verbatim: confirm)
                        .font(Theme.font(.s, .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 10.ui)
                        .frame(height: 24.ui)
                        .background(Capsule().fill(destructive ? Theme.failed : Theme.primary))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if !isQuestion {
                Button { module.dismissPrompt() } label: {
                    Image(systemName: "xmark").font(.system(size: 9.ui, weight: .bold)).foregroundStyle(Theme.tertiary)
                        .frame(width: 22.ui, height: 22.ui).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ControlText.t("Close"))
            }
        }
        .padding(.horizontal, 12.ui)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).fill(Theme.card))
    }

    private var symbol: String {
        switch prompt {
        case .confirmFinder: "arrow.clockwise"
        case .confirmTrash: "trash"
        case .needsAutomation: "hand.raised.fill"
        case .needsCamera: "video.slash.fill"
        case .note(_, let s): s
        }
    }

    private var tint: Color {
        switch prompt {
        case .confirmTrash: Theme.failed
        case .needsAutomation, .needsCamera: Theme.waiting
        default: Theme.secondary
        }
    }

    private var title: String {
        switch prompt {
        case .confirmFinder(let flag, let on):
            switch flag {
            case .desktopIcons: on ? ControlText.t("Hide desktop icons") : ControlText.t("Show desktop icons")
            case .hiddenFiles: on ? ControlText.t("Show hidden files") : ControlText.t("Hide hidden files")
            }
        case .confirmTrash: ControlText.t("Empty the Trash?")
        case .needsAutomation: ControlText.t("Automation needed")
        case .needsCamera: ControlText.t("The mirror needs the camera.")
        case .note(let text, _): text
        }
    }

    private var detail: String? {
        switch prompt {
        case .confirmFinder: ControlText.t("Finder restarts to apply this. Open windows come back.")
        case .confirmTrash(let s): ControlText.trash(s) + " · " + ControlText.t("It can't be undone.")
        case .needsAutomation(let app): L10n.tr("Allow Glancy to control %@ in Privacy → Automation.", app)
        case .needsCamera: ControlText.t("Allow it in Privacy → Camera.")
        case .note: nil
        }
    }

    private var confirm: String? {
        switch prompt {
        case .confirmFinder: ControlText.t("Restart Finder")
        case .confirmTrash: ControlText.t("Empty now")
        case .needsAutomation, .needsCamera: ControlText.t("Open Settings")
        case .note: nil
        }
    }

    /// A yes/no question (Cancel + confirm); otherwise a notice closed with ×.
    private var isQuestion: Bool {
        switch prompt {
        case .confirmFinder, .confirmTrash: true
        default: false
        }
    }

    private var destructive: Bool { if case .confirmTrash = prompt { true } else { false } }
}

// MARK: - Colour

extension RGB {
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
}

private struct ColorBar: View {
    let module: ControlModule
    let color: RGB
    let recent: [RGB]

    var body: some View {
        HStack(spacing: 12.ui) {
            RoundedRectangle(cornerRadius: 9.ui, style: .continuous)
                .fill(color.color)
                .overlay(RoundedRectangle(cornerRadius: 9.ui, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5.ui))
                .frame(width: 48.ui, height: 48.ui)
            VStack(alignment: .leading, spacing: 2.ui) {
                HStack(spacing: 6.ui) {
                    Text(verbatim: color.hex)
                        .font(.system(size: 15.ui, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.primary)
                    Label(ControlText.t("Copied"), systemImage: "checkmark")
                        .font(Theme.font(.xs, .medium)).foregroundStyle(Theme.done)
                }
                Text(verbatim: color.rgbString)
                    .font(.system(size: 10.5.ui, design: .monospaced)).foregroundStyle(Theme.tertiary)
                HStack(spacing: 4.ui) {
                    ForEach(recent.prefix(RecentColors.limit), id: \.self) { c in
                        Button { module.picked(c, announce: false) } label: {
                            Circle().fill(c.color)
                                .overlay(Circle().strokeBorder(c == color ? Theme.primary : Color.white.opacity(0.2),
                                                               lineWidth: c == color ? 1.5 : 0.5))
                                .frame(width: 14.ui, height: 14.ui)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(c.hex)
                    }
                }
                .padding(.top, 2.ui)
            }
            Spacer(minLength: 6.ui)
            VStack(spacing: 6.ui) {
                RoundAction(symbol: "eyedropper", help: ControlText.t("Pick a color")) { module.pickColor() }
                RoundAction(symbol: "xmark", help: ControlText.t("Close")) { module.dismissColor() }
            }
        }
        .padding(.horizontal, 10.ui)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).fill(Theme.card))
    }
}

private struct RoundAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5.ui, weight: .bold))
                .foregroundStyle(hover ? Theme.primary : Theme.secondary)
                .frame(width: 24.ui, height: 24.ui)
                .background(Circle().fill(Color.white.opacity(hover ? 0.14 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Mirror

private struct MirrorPanel: View {
    let module: ControlModule
    let live: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if live {
                    MirrorPreview()
                } else {
                    ZStack {
                        LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
                        VStack(spacing: 6.ui) {
                            Image(systemName: "person.crop.square").font(.system(size: 26.ui, weight: .light))
                            Text(verbatim: ControlText.t("Camera preview")).font(Theme.font(.s))
                        }
                        .foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            RoundAction(symbol: "xmark", help: ControlText.t("Close")) { module.toggleMirror() }
                .padding(8.ui)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stats

private struct StatsCard: View {
    let stats: StatsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5.ui) {
            HStack {
                Caption(text: ControlText.t("System"))
                Spacer(minLength: 4.ui)
                if let up = stats.uptime {
                    Text(verbatim: L10n.tr("up %@", ControlFormat.uptime(up)))
                        .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                // Monitor link (lot MON): the full monitor, when that module is on.
                if let open = MonitorLink.open {
                    Button(action: open) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5.ui, weight: .bold)).foregroundStyle(Theme.tertiary)
                            .frame(width: 14.ui, height: 14.ui).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("System monitor"))
                }
            }
            StatRow(symbol: "cpu", label: ControlText.t("CPU"),
                    value: stats.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", fraction: stats.cpu)
            StatRow(symbol: "memorychip", label: ControlText.t("Memory"),
                    value: stats.memory.map { gb($0.used) + " / " + gb($0.total, whole: true) + " GB" } ?? "—",
                    fraction: stats.memory.map { Double($0.used) / Double(max($0.total, 1)) },
                    tint: stats.memory.map { $0.pressure >= 4 ? Theme.failed : $0.pressure >= 2 ? Theme.waiting : Theme.secondary } ?? Theme.secondary)
            StatRow(symbol: "internaldrive", label: ControlText.t("Disk"),
                    value: stats.disk.map { L10n.tr("%@ free", ControlFormat.bytes($0.free)) } ?? "—",
                    fraction: stats.disk.map { 1 - Double($0.free) / Double(max($0.total, 1)) })
            HStack(spacing: 6.ui) {
                Image(systemName: "network").font(.system(size: 9.5.ui, weight: .semibold)).foregroundStyle(Theme.tertiary).frame(width: 14.ui)
                Text(verbatim: "↓ " + (stats.down.map(ControlFormat.rate) ?? "—"))
                Spacer(minLength: 2.ui)
                Text(verbatim: "↑ " + (stats.up.map(ControlFormat.rate) ?? "—"))
            }
            .font(Theme.font(.xs, .medium)).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1)
            .frame(height: 16.ui)
            if let b = stats.battery {
                HStack(spacing: 6.ui) {
                    Image(systemName: "battery.100percent").font(.system(size: 9.5.ui, weight: .semibold)).foregroundStyle(Theme.tertiary).frame(width: 14.ui)
                    Text(verbatim: L10n.tr("health %d%%", Int((min(b.health, 1) * 100).rounded())))
                        .layoutPriority(1)   // the cycles give way first
                    Spacer(minLength: 2.ui)
                    Text(verbatim: L10n.tr("%d cycles", b.cycles)).foregroundStyle(Theme.tertiary)
                }
                .font(Theme.font(.xs, .medium)).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1)
                .frame(height: 16.ui)
            }
        }
        .padding(10.ui)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).fill(Theme.card))
    }

    /// "10.6" used, "16" installed (RAM comes in whole gigabytes).
    private func gb(_ b: UInt64, whole: Bool = false) -> String {
        String(format: whole ? "%.0f" : "%.1f", Double(b) / 1_073_741_824)
    }
}

private struct StatRow: View {
    let symbol: String
    let label: String
    let value: String
    let fraction: Double?
    var tint: Color = Theme.secondary

    var body: some View {
        VStack(spacing: 2.ui) {
            HStack(spacing: 6.ui) {
                Image(systemName: symbol).font(.system(size: 9.5.ui, weight: .semibold)).foregroundStyle(Theme.tertiary).frame(width: 14.ui)
                Text(verbatim: label).foregroundStyle(Theme.tertiary)
                Spacer(minLength: 2.ui)
                Text(verbatim: value).foregroundStyle(Theme.secondary)
            }
            .font(Theme.font(.xs, .medium)).monospacedDigit().lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(tint).frame(width: geo.size.width * min(1, max(0, fraction ?? 0)))
                }
            }
            .frame(height: 2.5.ui)
            .padding(.leading, 20.ui)
        }
    }
}

// MARK: - Wings, peeks, Home

struct AwakeWingLeft: View {
    var body: some View {
        Image(systemName: "cup.and.saucer.fill")
            .font(.system(size: 11.ui, weight: .semibold))
            .foregroundStyle(Theme.waiting)
            .padding(.leading, 6.ui)
    }
}

/// Static text (the end time, or ∞): nothing ticks while collapsed.
struct AwakeWingRight: View {
    let until: Date?
    var body: some View {
        Text(verbatim: until.map { ControlText.time($0) } ?? "∞")
            .font(Theme.font(.s, .medium)).monospacedDigit()
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .padding(.trailing, 6.ui)
            .frame(maxWidth: Theme.wingMaxWidth, alignment: .trailing)
    }
}

struct ControlPeek: View {
    let symbol: String
    let title: String
    let detail: String?
    var body: some View {
        HStack(spacing: 8.ui) {
            Image(systemName: symbol).font(.system(size: 12.ui, weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(verbatim: title).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
            if let detail { Text(verbatim: detail).font(Theme.font(.m)).foregroundStyle(Theme.secondary) }
        }
        .lineLimit(1)
    }
}

struct ColorPeek: View {
    let color: RGB
    var body: some View {
        HStack(spacing: 8.ui) {
            RoundedRectangle(cornerRadius: 4.ui, style: .continuous).fill(color.color)
                .overlay(RoundedRectangle(cornerRadius: 4.ui, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5.ui))
                .frame(width: 16.ui, height: 16.ui)
            Text(verbatim: color.hex).font(.system(size: 12.ui, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.primary)
            Text(verbatim: ControlText.t("Copied")).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
        }
        .lineLimit(1)
    }
}

struct ControlHomeCard: View {
    let module: ControlModule
    let model: ControlModel
    var body: some View {
        HStack(spacing: 10.ui) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 13.ui, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(width: 30.ui, height: 30.ui)
                .background(Circle().fill(Theme.waiting))
            VStack(alignment: .leading, spacing: 1.ui) {
                Caption(text: ControlText.t("Keep awake"))
                Text(verbatim: model.awake.until.map { L10n.tr("Awake until %@", ControlText.time($0)) } ?? ControlText.t("Awake, no end"))
                    .font(Theme.font(.l, .medium)).monospacedDigit()
                    .foregroundStyle(Theme.primary).lineLimit(1)
            }
            Spacer(minLength: 6.ui)
            NotchTextButton(ControlText.t("Stop")) { module.stopAwake() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
