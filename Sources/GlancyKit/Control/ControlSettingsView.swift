import SwiftUI

/// Settings → Control: which tiles show and their order, keep-awake default, screenshots.
struct ControlSection: View {
    let module: ControlModule

    var body: some View {
        @Bindable var settings = module.settings
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsRow(ControlText.t("Keep awake by default"), note: ControlText.t("The length the tile starts with")) {
                NotchSegments(selection: $settings.awakeDefault, options: AwakeDuration.allCases.map { ($0, $0.label) })
            }
            SettingsRow(ControlText.t("Keep awake in the notch"), note: ControlText.t("A cup in the wings while it's on")) {
                NotchSwitch(isOn: Binding(get: { settings.awakeInWings },
                                          set: { settings.awakeInWings = $0; module.settingsChanged() }))
            }
            SettingsRow(ControlText.t("Screenshots go to")) {
                NotchSegments(selection: $settings.screenshotTarget,
                              options: [(.clipboard, ControlText.t("Clipboard")), (.desktop, ControlText.t("Desktop"))])
            }
            SettingsGroupTitle(ControlText.t("Tiles"))
            SettingsNote(ControlText.t("Click a tile to show or hide it; arrows move it within its row."))
            tiles(ControlText.t("Toggles"), settings.layout.order.filter(\.isToggle))
            tiles(ControlText.t("Tools"), settings.layout.order.filter { !$0.isToggle })
            HStack(alignment: .firstTextBaseline) {
                SettingsNote(ControlText.t("Dark mode asks for Automation (System Events); Empty Trash for Automation (Finder); the mirror for the camera, on first use."))
                Spacer()
                if settings.layout != ControlLayout() || settings.awakeDefault != .h1
                    || !settings.awakeInWings || settings.screenshotTarget != .clipboard {
                    NotchTextButton(tr("Reset")) { settings.reset(); module.settingsChanged() }
                }
            }
        }
    }

    private func tiles(_ title: String, _ list: [ControlTile]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: title)
                .font(SettingsStyle.font(.m)).foregroundStyle(SettingsStyle.primary).lineLimit(1)
                .frame(width: 80, height: 24, alignment: .leading)
            FlowLayout(spacing: 6) {
                ForEach(list, id: \.self) { tile in TileChip(module: module, tile: tile) }
            }
        }
        .padding(.vertical, 6)
        .settingsRow()
    }
}

private struct TileChip: View {
    let module: ControlModule
    let tile: ControlTile

    var body: some View {
        let layout = module.settings.layout
        let on = !layout.hidden.contains(tile)
        HStack(spacing: 0) {
            arrow("chevron.left", -1, ControlText.t("Move left"))
            Button {
                var l = module.settings.layout
                if on { l.hidden.insert(tile) } else { l.hidden.remove(tile) }
                module.settings.layout = l
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tile.symbol).font(.system(size: 10, weight: .semibold))
                    Text(verbatim: ControlText.t(tile.title)).font(SettingsStyle.font(.s, .medium)).lineLimit(1)
                }
                .foregroundStyle(on ? SettingsStyle.primary : SettingsStyle.faint)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            arrow("chevron.right", 1, ControlText.t("Move right"))
        }
        .frame(height: 24)
        .background(Capsule().fill(on ? SettingsStyle.selected : .clear))
        .overlay(Capsule().strokeBorder(on ? .clear : SettingsStyle.hairline, lineWidth: 1))
    }

    private func arrow(_ symbol: String, _ step: Int, _ help: String) -> some View {
        let can = module.settings.layout.canMove(tile, by: step)
        return Button {
            var l = module.settings.layout
            l.move(tile, by: step)
            module.settings.layout = l
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(can ? SettingsStyle.secondary : SettingsStyle.faint.opacity(0.5))
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!can)
        .help(help)
    }
}
