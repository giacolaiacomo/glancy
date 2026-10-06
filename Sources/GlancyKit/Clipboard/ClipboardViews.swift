import AppKit
import SwiftUI

// The Clipboard tab: search + list (pinned, recent) on the left, a preview of the hovered or
// selected item on the right. Works with key focus (type, ↑↓, ⏎) and without (click, scroll).
// Theme only.

struct ClipboardTabView: View {
    let model: ClipboardModel
    let onPasteSetting: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8.ui) {
            ClipHeader(model: model, onPasteSetting: onPasteSetting)
            HStack(alignment: .top, spacing: 10.ui) {
                ClipList(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                ClipPreview(model: model, item: model.previewItem)
                    .frame(width: 176.ui)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Header

private struct ClipHeader: View {
    let model: ClipboardModel
    let onPasteSetting: (Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8.ui) {
            HStack(spacing: 6.ui) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.font(.s, .medium))
                    .foregroundStyle(Theme.tertiary)
                TextField("", text: Bindable(model).query,
                          prompt: Text(ClipText.t("Search clipboard")).foregroundColor(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.font(.m))
                    .foregroundStyle(Theme.primary)
                    .focused($focused)
                    .onSubmit { model.chooseSelected() }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Theme.font(.s))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Text("\(model.filtered.count)")
                    .font(Theme.font(.xs, .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 8.ui)
            .frame(height: 24.ui)
            .background(RoundedRectangle(cornerRadius: 8.ui, style: .continuous).fill(Theme.card))
            .onAppear { focused = true }

            if !model.copyKeysSeen {
                Button { CopyKeyTap.requestPermission() } label: {
                    HStack(spacing: 4.ui) {
                        Image(systemName: "exclamationmark.circle")
                        Text(ClipText.t("⌘C not seen"))
                    }
                    .font(Theme.font(.xs, .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 7.ui)
                    .frame(height: 22.ui)
                    .background(Capsule().fill(Theme.card))
                }
                .buttonStyle(.plain)
                .help(ClipText.t("Copies show up when you switch app or open Glancy. Allow Input Monitoring to catch ⌘C at once."))
            }

            if model.settings.paused {
                Button { model.settings.paused = false } label: {
                    HStack(spacing: 4.ui) {
                        Image(systemName: "pause.fill")
                        Text(ClipText.t("History paused"))
                    }
                    .font(Theme.font(.xs, .medium))
                    .foregroundStyle(Theme.waiting)
                    .padding(.horizontal, 7.ui)
                    .frame(height: 22.ui)
                    .background(Capsule().fill(Theme.card))
                }
                .buttonStyle(.plain)
                .help(ClipText.t("Resume"))
            }

            ClipMenu(model: model, onPasteSetting: onPasteSetting)
        }
    }
}

private struct ClipMenu: View {
    let model: ClipboardModel
    let onPasteSetting: (Bool) -> Void

    var body: some View {
        let settings = model.settings
        Menu {
            Toggle(ClipText.t("Pause history"), isOn: Bindable(settings).paused)
            Toggle(ClipText.t("Paste after choosing"), isOn: Binding(
                get: { settings.pasteAfterChoosing },
                set: { settings.pasteAfterChoosing = $0; onPasteSetting($0) }))
            Menu(ClipText.t("Excluded apps")) {
                if settings.excluded.isEmpty {
                    Text(ClipText.t("No excluded apps"))
                } else {
                    ForEach(settings.excluded.sorted { $0.value < $1.value }, id: \.key) { id, name in
                        Button { model.include(bundleID: id) } label: { Label(name, systemImage: "checkmark") }
                    }
                }
            }
            Divider()
            Button(ClipText.t("Clear all…")) { model.confirmingClear = true }
                .disabled(model.items.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.font(.m, .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 26.ui, height: 22.ui)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: List

private struct ClipList: View {
    let model: ClipboardModel

    var body: some View {
        let sections = ClipboardHistory.sections(model.filtered)
        let selectedID = model.selectedItem?.id
        ZStack(alignment: .bottom) {
            if model.items.isEmpty {
                if model.loaded { ClipEmpty(title: "Nothing copied yet", body: ClipText.emptyBody(model.settings.hotkey)) }
            } else if sections.pinned.isEmpty && sections.recent.isEmpty {
                ClipEmpty(title: "No matches", body: nil)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 1.ui) {
                            if !sections.pinned.isEmpty {
                                ClipSectionTitle(ClipText.t("Pinned"))
                                ForEach(sections.pinned) { item in
                                    ClipRow(model: model, item: item, selected: item.id == selectedID).id(item.id)
                                }
                                ClipSectionTitle(ClipText.t("Recent")).padding(.top, 3.ui)
                            }
                            ForEach(sections.recent) { item in
                                ClipRow(model: model, item: item, selected: item.id == selectedID).id(item.id)
                            }
                        }
                        .padding(.bottom, model.confirmingClear ? 40.ui : 0)
                    }
                    .onChange(of: selectedID) { _, id in
                        guard let id, model.hovered == nil else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                    }
                }
            }
            if model.confirmingClear { ClipClearBar(model: model) }
        }
    }
}

private struct ClipSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.font(.xs, .semibold))
            .tracking(0.6.ui)
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 6.ui)
            .padding(.vertical, 2.ui)
    }
}

private struct ClipRow: View {
    let model: ClipboardModel
    let item: ClipItem
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8.ui) {
            ClipGlyph(model: model, item: item, side: 22)
            (item.kind == .image
                ? Text(ClipText.kind(.image)) + Text("  " + item.preview).foregroundColor(Theme.tertiary)
                : Text(item.preview))
                .font(Theme.font(.m))
                .foregroundStyle(Theme.primary)
                .lineLimit((item.kind == .text || item.kind == .richText) && item.preview.count > 64 ? 2 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hover {
                ClipIconButton(symbol: item.pinned ? "pin.slash" : "pin", help: ClipText.t(item.pinned ? "Unpin" : "Pin")) {
                    model.togglePin(item)
                }
                ClipIconButton(symbol: "trash", help: ClipText.t("Delete")) { model.delete(item) }
            } else {
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8.ui, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                if let icon = model.thumbs.icon(item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 14.ui, height: 14.ui)
                }
                Text(ClipText.relative(item.date, now: model.now))
                    .font(Theme.font(.xs).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .frame(minWidth: 24.ui, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6.ui)
        .padding(.vertical, 3.ui)
        .frame(minHeight: 27.ui)
        .background(
            RoundedRectangle(cornerRadius: 7.ui, style: .continuous)
                .fill(selected ? Theme.card : hover ? Theme.hairline.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onHover { on in
            hover = on
            if on { model.hovered = item.id } else if model.hovered == item.id { model.hovered = nil }
        }
        .onTapGesture { model.choose(item) }
        .contextMenu {
            Button(ClipText.t("Copy")) { model.choose(item) }
            Button(ClipText.t(item.pinned ? "Unpin" : "Pin")) { model.togglePin(item) }
            Button(ClipText.t("Delete")) { model.delete(item) }
            if let id = item.sourceBundleID, let name = item.sourceName {
                Divider()
                Button(L10n.tr("Never record from %@", name)) { model.exclude(bundleID: id, name: name) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct ClipIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.font(.s, .medium))
                .foregroundStyle(hover ? Theme.primary : Theme.secondary)
                .frame(width: 22.ui, height: 20.ui)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The type glyph, or the image's thumbnail.
private struct ClipGlyph: View {
    let model: ClipboardModel
    let item: ClipItem
    let side: CGFloat

    var body: some View {
        let px = Int(side * 2) * 2
        ZStack {
            RoundedRectangle(cornerRadius: 5.ui, style: .continuous).fill(Theme.card)
            if let img = model.thumbs.image(item, pixels: px) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 5.ui, style: .continuous))
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: side * 0.48, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: side, height: side)
        .task(id: item.imageBlob) {
            await model.thumbs.load(item, blobs: model.disk.blobs, pixels: px)
        }
    }
}

private struct ClipEmpty: View {
    let title: String
    let body_: String?
    init(title: String, body: String?) { self.title = title; self.body_ = body }

    var body: some View {
        VStack(spacing: 6.ui) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 18.ui, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(ClipText.t(title))
                .font(Theme.font(.l, .semibold))
                .foregroundStyle(Theme.secondary)
            if let body_ {
                Text(ClipText.t(body_))
                    .font(Theme.font(.s))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240.ui)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClipClearBar: View {
    let model: ClipboardModel

    var body: some View {
        HStack(spacing: 8.ui) {
            Text(L10n.tr("Clear all %d items, pinned included?", model.items.count))
                .font(Theme.font(.s))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(ClipText.t("Cancel")) { model.confirmingClear = false }
                .buttonStyle(.plain)
                .font(Theme.font(.s, .medium))
                .foregroundStyle(Theme.secondary)
            Button(ClipText.t("Clear")) { model.clearAll() }
                .buttonStyle(.plain)
                .font(Theme.font(.s, .semibold))
                .foregroundStyle(Theme.failed)
        }
        .padding(.horizontal, 10.ui)
        .frame(height: 32.ui)
        .background(RoundedRectangle(cornerRadius: 9.ui, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 9.ui, style: .continuous).stroke(Theme.hairline))
    }
}

// MARK: Preview

private struct ClipPreview: View {
    let model: ClipboardModel
    let item: ClipItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6.ui) {
            if let item {
                content(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer(item)
            }
        }
        .padding(9.ui)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12.ui, style: .continuous).fill(Theme.card))
    }

    @ViewBuilder private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .image:
            ClipPreviewImage(model: model, item: item)
        case .url:
            VStack(alignment: .leading, spacing: 3.ui) {
                Text(URL(string: item.text)?.host ?? item.text)
                    .font(Theme.font(.l, .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(item.text)
                    .font(Theme.font(.s))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(5)
            }
        case .files:
            VStack(alignment: .leading, spacing: 4.ui) {
                ForEach(item.fileURLs.prefix(5), id: \.self) { url in
                    HStack(spacing: 6.ui) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16.ui, height: 16.ui)
                        Text(url.lastPathComponent)
                            .font(Theme.font(.s))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if item.fileURLs.count > 5 {
                    Text("+\(item.fileURLs.count - 5)")
                        .font(Theme.font(.xs).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
                if let folder = item.fileURLs.first?.deletingLastPathComponent().path {
                    Text((folder as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        case .text, .richText:
            Text(String(item.text.prefix(1200)))
                .font(Theme.font(.s))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(1.ui)
                .clipped()
        }
    }

    private func footer(_ item: ClipItem) -> some View {
        HStack(spacing: 5.ui) {
            if let icon = model.thumbs.icon(item.sourceBundleID) {
                Image(nsImage: icon).resizable().frame(width: 12.ui, height: 12.ui)
            }
            Text([item.sourceName, ClipText.relative(item.date, now: model.now)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(Theme.font(.xs))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4.ui)
            Text(ClipText.t(model.settings.pasteAfterChoosing ? "⏎ paste" : "⏎ copy"))
                .font(Theme.font(.xs, .medium))
                .foregroundStyle(Theme.tertiary)
        }
    }
}

private struct ClipPreviewImage: View {
    let model: ClipboardModel
    let item: ClipItem
    static let pixels = 360

    var body: some View {
        Group {
            if let img = model.thumbs.image(item, pixels: Self.pixels) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6.ui, style: .continuous))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.imageBlob) {
            await model.thumbs.load(item, blobs: model.disk.blobs, pixels: Self.pixels)
        }
    }
}
