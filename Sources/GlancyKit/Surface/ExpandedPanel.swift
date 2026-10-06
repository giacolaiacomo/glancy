import SwiftUI

/// The expanded panel: tab icons in the band left of the notch, the gear right of it, and the
/// selected page below. Built when the panel opens and destroyed when it closes.
struct ExpandedPanel: View {
    let model: SurfaceModel
    let context: SurfaceContext

    var body: some View {
        let notch = model.geometry.notchRect.size
        let inset = Theme.openTopRadius + 10
        VStack(spacing: 0) {
            // The hardware notch covers the middle of the top band: icons go either side of it,
            // Home and the first half on the left, the rest and the gear on the right.
            TabBand(model: model, context: context, notchWidth: notch.width, inset: inset)
                .frame(height: notch.height)

            // A fixed content height: a tall page scrolls or clips, it never pushes the tab strip.
            page
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: max(0, Theme.expandedSize.height - notch.height - 8 - Theme.panelPadding), alignment: .top)
                .clipped()
                .padding(.top, 8)
                .padding(.horizontal, Theme.openTopRadius + Theme.panelPadding - 6)
                .padding(.bottom, Theme.panelPadding)
        }
        // A language change rebuilds the page with the new strings.
        .id(context.settings.language)
    }

    @ViewBuilder private var page: some View {
        if model.showingSettings {
            ScrollView(.vertical, showsIndicators: false) { SettingsPage(context: context) }
                .transition(.blurFade)
        } else if let id = model.selectedTab, let tab = context.tabs.first(where: { $0.module == id }) {
            tab.content()
                .id(id)
                .transition(.blurFade)
        } else {
            HomePage(context: context)
                .transition(.blurFade)
        }
    }
}

/// The top band: tab icons left and right of the hardware notch, never under it.
private struct TabBand: View {
    let model: SurfaceModel
    let context: SurfaceContext
    let notchWidth: CGFloat
    let inset: CGFloat

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let selected: Bool
        let action: () -> Void
    }

    var body: some View {
        let items = allItems
        // Home + tabs split in two; the gear always closes the right side.
        let leftCount = TabBandLayout.leftCount(items: items.count)
        let left = Array(items.prefix(leftCount)), right = Array(items.dropFirst(leftCount))
        let gear = Item(id: "gear", symbol: "gearshape", title: tr("Settings"), selected: model.showingSettings) {
            model.toggleSettings()
        }
        GeometryReader { geo in
            let slot = TabBandLayout.slot(width: geo.size.width, notchWidth: notchWidth, inset: inset, items: items.count)
            HStack(spacing: 0) {
                HStack(spacing: 0) { ForEach(left) { icon($0, slot) } }
                Spacer(minLength: notchWidth + 2 * TabIcon.gap)
                HStack(spacing: 0) {
                    ForEach(right) { icon($0, slot) }
                    icon(gear, slot)
                }
            }
            .padding(.horizontal, inset)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func icon(_ i: Item, _ slot: CGFloat) -> some View {
        TabIcon(symbol: i.symbol, title: i.title, selected: i.selected, action: i.action)
            .frame(width: slot)
    }

    private var allItems: [Item] {
        var list = [Item(id: "home", symbol: "house", title: tr("Home"),
                         selected: !model.showingSettings && model.selectedTab == nil) { model.select(tab: nil) }]
        for tab in context.stripTabs {
            list.append(Item(id: tab.module.rawValue, symbol: tab.symbol, title: tr(SurfaceContext.name(tab.module)),
                             selected: !model.showingSettings && model.selectedTab == tab.module) {
                model.select(tab: tab.module)
            })
        }
        return list
    }
}

/// The band's arithmetic: Home + tabs (`items`) split either side of the notch, the gear last on
/// the right; every icon gets the same slot, at most `TabIcon.slot`.
@MainActor
enum TabBandLayout {
    static func leftCount(items: Int) -> Int { (items + 1 + 1) / 2 }      // +1 for the gear on the right

    /// Width of one icon slot when the band is `width` wide.
    static func slot(width: CGFloat, notchWidth: CGFloat, inset: CGFloat, items: Int) -> CGFloat {
        // Room on each side of the notch (a small gap keeps icons off its rounded edge).
        let side = max(0, (width - notchWidth) / 2 - inset - TabIcon.gap)
        let left = leftCount(items: items), right = items - left + 1
        let slots = CGFloat(max(left, right, 1))
        return min(TabIcon.slot, (side / slots).rounded(.down))
    }

    /// The panel's own band: `Theme.expandedSize` beside a notch, the inset `ExpandedPanel` uses.
    static func slot(notchWidth: CGFloat, items: Int) -> CGFloat {
        slot(width: Theme.expandedSize.width, notchWidth: notchWidth, inset: Theme.openTopRadius + 10, items: items)
    }

    static var fullSlot: CGFloat { TabIcon.slot }
    /// The drawn capsule; a slot narrower than this makes icons touch.
    static var iconWidth: CGFloat { TabIcon.iconWidth }
}

private struct TabIcon: View {
    /// Width of one icon slot, and the clearance kept from the notch's edge.
    static let slot: CGFloat = 30
    static let gap: CGFloat = 8
    static let iconWidth: CGFloat = 28
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .symbolVariant(selected ? .fill : .none)
                .foregroundStyle(selected ? Theme.primary : hover ? Theme.secondary : Theme.tertiary)
                .frame(width: Self.iconWidth, height: 22)
                .background(Capsule().fill(selected ? Theme.card : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Home: glance rows stacked on the left (meeting, sessions, timer…), the media tile on the right.
/// Rows get the width they need to read; nothing is squeezed into thirds.
struct HomePage: View {
    let context: SurfaceContext

    var body: some View {
        let cards = context.enabledModules.compactMap { m in m.homeCard().map { (m.id, $0) } }
        // Two glance rows on the left; the right tile is media, or else the third card.
        // Most urgent first (live priority: waiting agent 90, meeting now 85, timer ending 80…),
        // then the panel's usual order.
        let others = cards.filter { $0.0 != .media }.enumerated().sorted { a, b in
            let pa = context.hub.priority(of: a.element.0), pb = context.hub.priority(of: b.element.0)
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map(\.element)
        let rows = Array(others.prefix(2))
        let tile = cards.first { $0.0 == .media } ?? others.dropFirst(2).first
        if cards.isEmpty {
            EmptyHome()
        } else {
            HStack(alignment: .top, spacing: 10) {
                if !rows.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(rows, id: \.0) { card in HomeCard { card.1 } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if let tile {
                    HomeCard { tile.1 }
                        .frame(width: rows.isEmpty ? nil : 196)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

/// The card frame every Home card sits in.
struct HomeCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }
}

private struct EmptyHome: View {
    var body: some View {
        VStack(spacing: 8) {
            GlancyGlyph()
                .fill(Theme.tertiary)
                .frame(width: 22, height: 11)
            Text(tr("All quiet"))
                .font(Theme.font(.l, .semibold))
                .foregroundStyle(Theme.secondary)
            Text(tr("Your next meeting, live sessions and what is playing will show up here."))
                .font(Theme.font(.s))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 6)
    }
}

/// The brand mark: a half-moon hanging from a flat top edge, the shape of a lunette.
public struct GlancyGlyph: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.midX, y: rect.minY), radius: rect.width / 2,
                 startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Fade through a blur, like `.blurReplace` but without its scale. A scaled transition redraws
/// every text it moves at each in-between size, and CoreGraphics keeps a glyph bitmap for every
/// size it has drawn: ~18 MB of glyphs after a walk through the tabs, held for good.
struct BlurFade: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .blur(radius: phase.isIdentity ? 0 : 8)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

extension Transition where Self == BlurFade {
    static var blurFade: BlurFade { BlurFade() }
}
