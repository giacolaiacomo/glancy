import SwiftUI

// HUD wings: the symbol on the left, a slim level bar and the percentage on the right. Theme only.

struct HUDWingLeft: View {
    let model: HUDModel
    var body: some View {
        let r = model.reading
        Image(systemName: r.symbol)
            .font(.system(size: 13.ui, weight: .semibold))
            .foregroundStyle(r.muted ? Theme.secondary : Theme.primary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 20.ui, alignment: .center)
            .fixedSize()
    }
}

struct HUDWingRight: View {
    let model: HUDModel
    var body: some View {
        let r = model.reading
        HStack(spacing: 6.ui) {
            HUDLevelBar(level: r.shownLevel, dimmed: r.muted)
            Text(verbatim: r.muted ? L10n.tr("Muted") : "\(HUDStep.percent(r.level))%")
                .font(Theme.font(.s, .medium).monospacedDigit())
                .foregroundStyle(r.muted ? Theme.tertiary : Theme.secondary)
                .lineLimit(1)
                .frame(minWidth: 32.ui, alignment: .trailing)
        }
        .fixedSize()
    }
}

struct HUDLevelBar: View {
    let level: Float
    var dimmed = false
    static var width: CGFloat { 46.ui }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.hairline)
            Capsule()
                .fill(dimmed ? Theme.tertiary : Theme.primary)
                .frame(width: max(level > 0 ? 4.ui : 0, Self.width * CGFloat(level)))
        }
        .frame(width: Self.width, height: 4.ui)
        .animation(Theme.peek, value: level)
    }
}
