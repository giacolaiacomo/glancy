import SwiftUI

// The shape every idle Home card shares (a widget set to Always with nothing going on): a quiet
// glyph, the widget's caption, one line that says something useful, and at most one action. No
// timers, no animation: it shows what its module already knows.

/// One idle Home row: glyph, caption, headline, an optional detail and an optional control on the
/// right. `open`: a click on the row (outside the control) opens the module.
struct HomeIdleRow<Trailing: View>: View {
    let symbol: String
    let caption: String
    let title: String
    var detail: String?
    var tint: Color = Theme.secondary
    var open: (() -> Void)?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10.ui) {
            label
                .contentShape(Rectangle())
                .onTapGesture { open?() }
            Spacer(minLength: 6.ui)
            trailing
        }
        // Top, like the cards with something: a row of mixed cards lines up.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var label: some View {
        HStack(spacing: 10.ui) {
            Image(systemName: symbol)
                .font(.system(size: 13.ui, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30.ui, height: 30.ui)
                .background(Circle().fill(Color.white.opacity(0.07)))
            VStack(alignment: .leading, spacing: 1.ui) {
                HomeCaption(text: caption)
                Text(verbatim: title)
                    .font(Theme.font(.l, .medium)).monospacedDigit()
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if let detail {
                    Text(verbatim: detail)
                        .font(Theme.font(.s)).monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
        }
    }
}

extension HomeIdleRow where Trailing == EmptyView {
    init(symbol: String, caption: String, title: String, detail: String? = nil, tint: Color = Theme.secondary,
         open: (() -> Void)? = nil) {
        self.init(symbol: symbol, caption: caption, title: title, detail: detail, tint: tint, open: open) { EmptyView() }
    }
}

/// The small caps caption the Home cards start with.
struct HomeCaption: View {
    let text: String
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 9.5.ui, weight: .semibold)).tracking(0.6.ui)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
    }
}
