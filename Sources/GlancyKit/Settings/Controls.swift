import SwiftUI

// Small controls drawn in SwiftUI, sized for the 12 pt panel and the black surface. They render
// identically on screen and in `glancy-render` (no AppKit-backed controls).

/// An on/off switch.
public struct NotchSwitch: View {
    @Binding var isOn: Bool
    var enabled = true

    public init(isOn: Binding<Bool>, enabled: Bool = true) { _isOn = isOn; self.enabled = enabled }

    public var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.done.opacity(0.9) : Color.white.opacity(0.16))
                Circle().fill(Color.white)
                    .padding(2.ui)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .frame(width: 28.ui, height: 16.ui)
            .animation(Theme.peek, value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

/// A compact segmented choice.
public struct NotchSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    public init(selection: Binding<Value>, options: [(Value, String)]) {
        _selection = selection; self.options = options
    }

    public var body: some View {
        HStack(spacing: 2.ui) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let on = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(Theme.font(.s, on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.black : Theme.secondary)
                        .padding(.horizontal, 8.ui)
                        .frame(height: 20.ui)
                        .background(Capsule().fill(on ? Theme.primary : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.ui)
        .background(Capsule().fill(Theme.card))
        .animation(Theme.peek, value: selection)
    }
}

/// A module chip: symbol + name, filled when on.
public struct NotchChip: View {
    let symbol: String
    let title: String
    let on: Bool
    let action: () -> Void

    public init(symbol: String, title: String, on: Bool, action: @escaping () -> Void) {
        self.symbol = symbol; self.title = title; self.on = on; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4.ui) {
                Image(systemName: symbol).font(.system(size: 10.ui, weight: .semibold))
                if !title.isEmpty { Text(title).font(Theme.font(.s, .medium)) }
            }
            .foregroundStyle(on ? Theme.primary : Theme.tertiary)
            .padding(.horizontal, 8.ui)
            .frame(height: 22.ui)
            .background(Capsule().fill(on ? Color.white.opacity(0.14) : .clear))
            .overlay(Capsule().strokeBorder(on ? .clear : Theme.hairline, lineWidth: 1.ui))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A text button in the panel's quiet style.
public struct NotchTextButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    public init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(.s, .medium))
                .foregroundStyle(hover ? Theme.primary : Theme.secondary)
                .padding(.horizontal, 9.ui)
                .frame(height: 22.ui)
                .background(Capsule().fill(hover ? Color.white.opacity(0.12) : Theme.card))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Wraps its children onto as many rows as they need.
public struct FlowLayout: Layout {
    var spacing: CGFloat = 5.ui
    public init(spacing: CGFloat = 5.ui) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? s.width : s.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let add = rows[rows.count - 1].indices.isEmpty ? s.width : s.width + spacing
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += add
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, s.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
