import AppKit
import SwiftUI

/// Where files dragged onto the notch can go. The Shelf is the default: a drop anywhere that is
/// not another target parks the files, exactly as before the split.
public enum ShelfDropAction: String, CaseIterable, Sendable {
    case shelf, airDrop, share, zip

    var symbol: String {
        switch self {
        case .shelf: "tray.and.arrow.down.fill"
        case .airDrop: "dot.radiowaves.left.and.right"
        case .share: "square.and.arrow.up"
        case .zip: "doc.zipper"
        }
    }

    @MainActor var title: String {
        switch self {
        case .shelf: L10n.tr("Shelf")
        case .airDrop: L10n.tr("AirDrop")
        case .share: L10n.tr("Share…")
        case .zip: L10n.tr("Zip")
        }
    }

    /// The target under `point` (in the targets' own coordinate space), nil = none of them.
    /// Frames are the tiles as laid out; the gaps between them belong to no target.
    public static func hit(_ point: CGPoint, frames: [ShelfDropAction: CGRect]) -> ShelfDropAction? {
        allCases.first { frames[$0]?.contains(point) == true }
    }

    /// What a drop does when the pointer is over `hovered` (nil → the Shelf).
    public static func resolve(_ hovered: ShelfDropAction?, targetsShown: Bool) -> ShelfDropAction {
        targetsShown ? hovered ?? .shelf : .shelf
    }
}

private let dropSpace = "shelf.dropTargets"

/// The split drop zone shown in the Shelf tab while files are dragged to the notch.
struct ShelfDropTargetsView: View {
    let model: ShelfModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ShelfDropAction.allCases, id: \.self) { action in
                DropTile(action: action, hovered: model.dropHover == action,
                         isDefault: model.dropHover == nil && action == .shelf,
                         subtitle: subtitle(action))
                    .frame(maxWidth: action == .shelf ? .infinity : 118)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(dropSpace)) } action: { model.dropFrames[action] = $0 }
            }
        }
        .coordinateSpace(.named(dropSpace))
        .background(ShelfDropProbe(model: model))
        .animation(Theme.peek, value: model.dropHover)
    }

    private func subtitle(_ action: ShelfDropAction) -> String {
        switch action {
        case .shelf: ShelfText.files(max(1, model.dropCount))
        case .airDrop: L10n.tr("Nearby devices")
        case .share: L10n.tr("Mail, Messages…")
        case .zip: model.dropCount == 1 ? L10n.tr("Beside the file") : L10n.tr("One archive")
        }
    }
}

private struct DropTile: View {
    let action: ShelfDropAction
    let hovered: Bool
    let isDefault: Bool
    let subtitle: String

    var body: some View {
        let lit = hovered || isDefault
        VStack(spacing: 7) {
            Image(systemName: action.symbol)
                .font(.system(size: action == .shelf ? 20 : 17, weight: .medium))
                .foregroundStyle(hovered ? Color.black : Theme.primary)
                .frame(width: action == .shelf ? 46 : 40, height: action == .shelf ? 46 : 40)
                .background(Circle().fill(hovered ? Theme.primary : Theme.card))
                .scaleEffect(hovered ? 1.08 : 1)
            VStack(spacing: 2) {
                Text(verbatim: action.title)
                    .font(Theme.font(.m, .semibold)).foregroundStyle(lit ? Theme.primary : Theme.secondary)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovered ? Theme.hairline : Theme.card.opacity(isDefault ? 1 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovered ? Theme.secondary : Theme.hairline,
                              style: StrokeStyle(lineWidth: hovered ? 1.5 : 1.2, dash: hovered ? [] : [5, 4]))
        )
        .accessibilityElement(children: .combine)
    }
}

/// An inert AppKit view behind the targets: converts the drag location (window coordinates) into
/// the targets' coordinate space, and anchors the share picker. It takes no clicks or drags.
private struct ShelfDropProbe: NSViewRepresentable {
    let model: ShelfModel

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        model.dropProbe = v
        return v
    }

    func updateNSView(_ view: ProbeView, context: Context) { model.dropProbe = view }

    final class ProbeView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
