import AppKit
import SwiftUI

private struct Caption: View {
    let text: String
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 9.5.ui, weight: .semibold)).tracking(0.6.ui)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
    }
}

/// A thumbnail that loads once per item through the shared, capped cache.
struct ShelfThumb: View {
    let shelf: ShelfModule
    let item: ShelfItem
    var size: CGFloat = 32.ui
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6.ui, style: .continuous).fill(Theme.card)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.id) {
            if let hit = shelf.thumbnails.cached(item.id) { image = hit; return }
            image = await shelf.thumbnails.image(for: item.id, url: shelf.model.url(item))
        }
    }
}

// MARK: - Wing while a drag hovers the notch

struct ShelfDragWing: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4.ui) {
            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 12.ui, weight: .medium))
            Text(verbatim: "\(count)").font(Theme.font(.s, .semibold)).monospacedDigit()
        }
        .foregroundStyle(Theme.primary)
        .padding(.leading, 6.ui)
    }
}

// MARK: - Home card

struct ShelfHomeCard: View {
    let shelf: ShelfModule
    let model: ShelfModel
    var body: some View {
        Button { shelf.openShelfTab() } label: {
            HStack(spacing: 10.ui) {
                HStack(spacing: -8.ui) {
                    ForEach(model.items.prefix(4)) { item in
                        ShelfThumb(shelf: shelf, item: item, size: 28.ui)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                }
                VStack(alignment: .leading, spacing: 2.ui) {
                    Caption(text: L10n.tr("Shelf"))
                    Text(verbatim: ShelfText.count(model.items.count))
                        .font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                }
                Spacer(minLength: 4.ui)
                Image(systemName: "chevron.right").font(.system(size: 10.ui, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tab

struct ShelfTabView: View {
    let shelf: ShelfModule
    let model: ShelfModel

    var body: some View {
        if model.dropTargetsShown {
            ShelfDropTargetsView(model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else if model.items.isEmpty && model.receiving == 0 && model.busy == 0 {
            EmptyShelf()
        } else {
            VStack(alignment: .leading, spacing: 6.ui) {
                toolbar
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64.ui, maximum: 72.ui), spacing: 4.ui)], spacing: 4.ui) {
                        ForEach(model.items) { item in
                            ShelfTile(shelf: shelf, model: model, item: item, selected: model.selection.contains(item.id))
                        }
                    }
                    .padding(.bottom, 4.ui)
                }
                .background(Color.black.opacity(0.001).onTapGesture { model.selection = [] })
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4.ui) {
            Caption(text: model.receiving > 0 ? L10n.tr("Receiving…")
                    : model.busy > 0 ? L10n.tr("Working…")
                    : model.selection.isEmpty ? ShelfText.count(model.items.count) : ShelfText.selected(model.selection.count))
            Spacer(minLength: 8.ui)
            ToolIcon(symbol: "eye", help: L10n.tr("Quick Look")) { shelf.quickLook() }
            ToolIcon(symbol: "dot.radiowaves.left.and.right", help: L10n.tr("AirDrop")) { shelf.airDrop() }
            ShareIcon(shelf: shelf)
            ToolIcon(symbol: "doc.on.doc", help: L10n.tr("Copy")) { shelf.copy() }
            ToolIcon(symbol: "doc.zipper", help: L10n.tr("Zip")) { shelf.zip() }
            ToolIcon(symbol: "folder", help: L10n.tr("Show in Finder")) { shelf.reveal() }
            MenuIcon(shelf: shelf, item: nil)
            Rectangle().fill(Theme.hairline).frame(width: 1.ui, height: 12.ui).padding(.horizontal, 2.ui)
            if !model.selection.isEmpty {
                ToolIcon(symbol: "minus.circle", help: L10n.tr("Remove")) { shelf.remove(model.selection) }
            }
            ToolIcon(symbol: "trash", help: L10n.tr("Clear shelf")) { shelf.clear() }
        }
        .frame(height: 22.ui)
    }
}

private struct EmptyShelf: View {
    var body: some View {
        VStack(spacing: 6.ui) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 22.ui, weight: .light)).foregroundStyle(Theme.secondary)
            Text(verbatim: L10n.tr("Drop files here")).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary)
            Text(verbatim: L10n.tr("Drag files, text or links onto the notch. They stay here until you remove them."))
                .font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 300.ui)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14.ui, style: .continuous)
                .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1.5.ui, dash: [5, 4]))
        )
    }
}

private struct ShelfTile: View {
    let shelf: ShelfModule
    let model: ShelfModel
    let item: ShelfItem
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4.ui) {
            ShelfThumb(shelf: shelf, item: item, size: 32.ui)
            Text(verbatim: item.name)
                .font(Theme.font(.xs)).foregroundStyle(selected ? Theme.primary : Theme.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.top, 6.ui).padding(.horizontal, 3.ui)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9.ui, style: .continuous).fill(selected ? Color.white.opacity(0.14) : .clear))
        .overlay(ShelfMouseArea(
            onDown: { _, event in click(event) },
            onDoubleClick: { shelf.quickLook(from: item) },
            onDrag: { view, event in dragOut(from: view, event: event) },
            onMenu: { shelf.menu(for: item) }))
        // Hover: the item's actions, one click away (right-click opens the same menu).
        .overlay(alignment: .topTrailing) {
            if hover || model.renderHover == item.id {
                MenuIcon(shelf: shelf, item: item, compact: true).padding(2.ui).transition(.opacity)
            }
        }
        .onHover { h in withAnimation(Theme.peek) { hover = h } }
        .help(item.name)
    }

    /// Click selects; ⌘-click toggles; ⇧-click extends from the last selected item.
    private func click(_ event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
        } else if flags.contains(.shift), let anchor = model.items.firstIndex(where: { model.selection.contains($0.id) }),
                  let here = model.items.firstIndex(of: item) {
            model.selection = Set(model.items[min(anchor, here)...max(anchor, here)].map(\.id))
        } else if !model.selection.contains(item.id) {
            model.selection = [item.id]
        }
    }

    /// Drags the selection if this tile is in it, otherwise just this tile.
    private func dragOut(from view: NSView, event: NSEvent) {
        let group = model.selection.contains(item.id) ? model.items.filter { model.selection.contains($0.id) } : [item]
        ShelfDragSource.shared.begin(urls: group.map { model.url($0) },
                                     images: group.map { shelf.thumbnails.cached($0.id) ?? NSWorkspace.shared.icon(forFile: model.url($0).path) },
                                     from: view, event: event)
    }
}

private struct ToolIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) { ToolGlyph(symbol: symbol, hover: hover) }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(help)
            .accessibilityLabel(help)
    }
}

private struct ToolGlyph: View {
    let symbol: String
    let hover: Bool
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11.ui, weight: .medium))
            .foregroundStyle(hover ? Theme.primary : Theme.secondary)
            .frame(width: 26.ui, height: 22.ui)
            .background(Capsule().fill(hover ? Theme.card : .clear))
            .contentShape(Rectangle())
    }
}

/// "…": every action on the selection (or on one item), as a menu.
private struct MenuIcon: View {
    let shelf: ShelfModule
    let item: ShelfItem?
    var compact = false
    @State private var hover = false
    var body: some View {
        Group {
            if compact {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9.ui, weight: .bold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 18.ui, height: 18.ui)
                    .background(Circle().fill(Color.black.opacity(0.75)))
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1.ui))
            } else {
                ToolGlyph(symbol: "ellipsis.circle", hover: hover)
            }
        }
        .overlay(ShelfMouseArea(onDown: { view, _ in
            let menu = shelf.menu(for: item)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }))
        .onHover { hover = $0 }
        .help(L10n.tr("More"))
        .accessibilityLabel(L10n.tr("More"))
    }
}

/// The Share button needs an AppKit view to anchor the picker.
private struct ShareIcon: View {
    let shelf: ShelfModule
    @State private var hover = false
    var body: some View {
        ToolGlyph(symbol: "square.and.arrow.up", hover: hover)
            .overlay(ShelfMouseArea(onDown: { view, _ in shelf.share(from: view) }))
            .onHover { hover = $0 }
            .help(L10n.tr("Share"))
            .accessibilityLabel(L10n.tr("Share"))
    }
}

/// Raw mouse handling for a tile: first-click aware (the panel is never key), double click, and
/// a drag that starts an AppKit dragging session (multi-item drags need one).
struct ShelfMouseArea: NSViewRepresentable {
    var onDown: (NSView, NSEvent) -> Void = { _, _ in }
    var onDoubleClick: () -> Void = {}
    var onDrag: ((NSView, NSEvent) -> Void)?
    var onMenu: (() -> NSMenu?)?

    func makeNSView(context: Context) -> MouseView { MouseView() }
    func updateNSView(_ view: MouseView, context: Context) {
        view.onDown = onDown; view.onDoubleClick = onDoubleClick; view.onDrag = onDrag; view.onMenu = onMenu
    }

    final class MouseView: NSView {
        var onDown: (NSView, NSEvent) -> Void = { _, _ in }
        var onDoubleClick: () -> Void = {}
        var onDrag: ((NSView, NSEvent) -> Void)?
        var onMenu: (() -> NSMenu?)?
        private var downAt: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Right-click / control-click: the item's actions.
        override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = onMenu?() {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
            downAt = event.locationInWindow
            if event.clickCount == 2 { onDoubleClick() } else { onDown(self, event) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = downAt, let onDrag else { return }
            let p = event.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
            downAt = nil
            onDrag(self, event)
        }

        override func mouseUp(with event: NSEvent) { downAt = nil }
    }
}
