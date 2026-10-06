import AppKit
import SwiftUI

// The command bar page: a search field on top (with what ⏎ and ⌘⏎ do), the results below.
// Keyboard: type, ↑↓, ⏎, ⌘⏎, ⌘1…9, Esc. Theme only.

struct CommandBarView: View {
    let model: CommandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6.ui) {
            CommandSearchField(model: model)
            if model.rows.isEmpty {
                CommandEmpty(model: model)
            } else {
                CommandResults(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Search field

private struct CommandSearchField: View {
    let model: CommandModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7.ui) {
            Image(systemName: "magnifyingglass")
                .font(Theme.font(.l, .medium))
                .foregroundStyle(Theme.tertiary)
            TextField("", text: Bindable(model).query,
                      prompt: Text(CommandText.t("Search apps, commands, math…")).foregroundColor(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Theme.font(.xl))
                .foregroundStyle(Theme.primary)
                .focused($focused)
                .onSubmit { model.handle(.enter) }
            if let item = model.selectedItem, item.actionable {
                HStack(spacing: 8.ui) {
                    KeyHint(key: "↵", label: item.primary)
                    if let s = item.secondary { KeyHint(key: "⌘↵", label: s.title) }
                }
                .fixedSize()
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10.ui)
        .frame(height: 30.ui)
        .background(RoundedRectangle(cornerRadius: 10.ui, style: .continuous).fill(Theme.card))
        .onAppear { focused = true }
        .onChange(of: model.visible) { _, on in if on { focused = true } }
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4.ui) {
            KeyCap(key)
            Text(verbatim: label)
                .font(Theme.font(.xs))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
    }
}

private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9.5.ui, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 4.ui)
            .frame(minWidth: 16.ui, minHeight: 15.ui)
            .background(RoundedRectangle(cornerRadius: 4.ui, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

// MARK: Results

private struct CommandResults: View {
    let model: CommandModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1.ui) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, item in
                        if let header = model.sections[i] {
                            SectionHeader(text: header)
                        }
                        CommandRow(item: item, index: i, selected: i == model.selection) { model.run(i) }
                            .id(item.id)
                    }
                }
            }
            .onChange(of: model.selection) { _, new in
                guard model.rows.indices.contains(new) else { return }
                proxy.scrollTo(model.rows[new].id)
            }
        }
    }
}

private struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 9.ui, weight: .semibold))
            .tracking(0.6.ui)
            .foregroundStyle(Theme.tertiary)
            .padding(.leading, 8.ui)
            .frame(height: 15.ui, alignment: .bottom)
            .padding(.bottom, 1.ui)
    }
}

private struct CommandRow: View {
    let item: PaletteItem
    let index: Int
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    private var big: Bool { item.kind == .answer || item.kind == .notice }

    var body: some View {
        HStack(spacing: 9.ui) {
            RowIcon(icon: item.icon, size: big ? 22.ui : 18.ui)
            if big {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: item.title)
                        .font(Theme.font(.xl, .semibold).monospacedDigit())
                        .foregroundStyle(item.kind == .notice ? Theme.secondary : Theme.primary)
                        .lineLimit(1)
                    if let s = item.subtitle {
                        Text(verbatim: s)
                            .font(Theme.font(.xs).monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                Text(verbatim: item.title)
                    .font(Theme.font(.m, selected ? .medium : .regular))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let s = item.subtitle {
                    Text(verbatim: s)
                        .font(Theme.font(.s))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8.ui)
            Text(verbatim: item.tag)
                .font(Theme.font(.xs))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .fixedSize()
            Group {
                if selected, item.actionable {
                    KeyCap("↵")
                } else if index < 9, item.actionable {
                    Text(verbatim: "⌘\(index + 1)")
                        .font(.system(size: 9.5.ui, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.tertiary.opacity(0.8))
                }
            }
            .frame(width: 22.ui, alignment: .trailing)
        }
        .padding(.horizontal, 8.ui)
        .frame(height: big ? 38.ui : 24.ui)
        .background(
            RoundedRectangle(cornerRadius: 7.ui, style: .continuous)
                .fill(selected ? Color.white.opacity(0.11) : hover ? Color.white.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { if item.actionable { action() } }
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct RowIcon: View {
    let icon: PaletteIcon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .app(let path):
            Image(nsImage: PaletteIcons.icon(path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.white.opacity(0.09)))
        }
    }
}

// MARK: Empty

/// Nothing yet (first open, or no match): a few things to try, clickable.
private struct CommandEmpty: View {
    let model: CommandModel

    var body: some View {
        let examples = L10n.isItalian
            ? ["12% di 340", "5 km in mi", "100 dollari in euro", "3 ore in min", "0xff"]
            : ["12% of 340", "5 km in mi", "100 usd to eur", "70 f to c", "0xff"]
        VStack(spacing: 10.ui) {
            if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(verbatim: CommandText.t("No results"))
                    .font(Theme.font(.m, .medium))
                    .foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 5.ui) {
                Text(verbatim: CommandText.t("Try"))
                    .font(Theme.font(.xs))
                    .foregroundStyle(Theme.tertiary)
                ForEach(examples, id: \.self) { e in
                    Button { model.query = e } label: {
                        Text(verbatim: e)
                            .font(Theme.font(.s))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8.ui)
                            .frame(height: 20.ui)
                            .background(Capsule().fill(Theme.card))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8.ui)
    }
}

// MARK: Settings → Command bar

struct CommandSection: View {
    let module: CommandModule
    let context: SurfaceContext
    @State private var system: Set<Hotkey> = []
    @State private var tick = 0

    var body: some View {
        @Bindable var settings = module.model.settings
        let _ = tick
        let history = module.model.history
        HStack(alignment: .top, spacing: 22.ui) {
            VStack(alignment: .leading, spacing: 4.ui) {
                SettingsRow(tr("Shortcut"), note: CommandText.t("Opens the bar from anywhere")) {
                    HotkeyField(id: "command", hotkey: settings.hotkey, conflict: conflict(settings.hotkey)) { h in
                        module.setHotkey(h)
                        tick += 1
                    }
                }
                SettingsRow(CommandText.t("History"), note: historyNote(history)) {
                    ConfirmButton(title: CommandText.t("Clear"), question: CommandText.t("Clear history?"), confirm: CommandText.t("Clear"),
                                  enabled: !history.store.entries.isEmpty || !history.isLoaded) {
                        history.clear()
                        tick += 1
                    }
                }
                SettingsNote(CommandText.t("Esc clears, then closes"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2.ui) {
                SettingsGroupTitle(CommandText.t("Results"))
                toggle(CommandText.t("Applications"), CommandText.t("Launch and reveal apps"), $settings.apps)
                toggle(CommandText.t("Calculator"), CommandText.t("Arithmetic, %, hex and binary"), $settings.calculator)
                toggle(CommandText.t("Units"), CommandText.t("Length, weight, temperature, data, time…"), $settings.units)
                toggle(CommandText.t("Exchange rates"), CommandText.t("Fetched from the ECB only when you type a currency"), $settings.currency)
                toggle(CommandText.t("Web search"), CommandText.t("Last row: search Google in your browser"), $settings.webSearch)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            system = HotkeyConflict.systemHotkeys()
            history.loadIfNeeded()
            tick += 1
        }
    }

    private func toggle(_ title: String, _ note: String, _ on: Binding<Bool>) -> some View {
        SettingsRow(title, note: note, minHeight: 24.ui) { NotchSwitch(isOn: on) }
    }

    private func historyNote(_ h: PaletteHistory) -> String {
        guard h.isLoaded, !h.store.entries.isEmpty else { return CommandText.t("Ranking learns from what you open") }
        return L10n.tr(CommandText.t("%d remembered"), h.store.entries.count)
    }

    private func conflict(_ h: Hotkey) -> HotkeyConflict? {
        let all = GlancyHotkeys.bindings(context)
        let failed: Set<Hotkey> = module.hotkeyFailed ? [h] : []
        return HotkeyConflict.find(HotkeyBinding(id: "command", title: CommandText.t("Command bar"), hotkey: h),
                                   among: all, system: system, failed: failed)
    }
}
