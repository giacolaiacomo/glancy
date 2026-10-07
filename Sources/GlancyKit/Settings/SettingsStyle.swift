import AppKit
import SwiftUI

// The Settings window's look: system type and colours (light and dark), grouped boxes like System
// Settings, at the normal size whatever the notch's Size (nothing here goes through `.ui`). The
// settings sections use these, never `Theme`'s ink-on-black.

/// The window's vocabulary, named like `Theme`'s so a section reads the same.
enum SettingsStyle {
    /// Theme's steps at window scale: body text is 13 pt, notes 11 pt.
    static func font(_ size: Theme.Size, _ weight: Font.Weight = .regular) -> Font {
        .system(size: points(size), weight: weight)
    }

    static func points(_ size: Theme.Size) -> CGFloat {
        switch size {
        case .xs: 11
        case .s: 12
        case .m: 13
        case .l: 15
        case .xl: 22
        }
    }

    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    /// Notes and quiet values: still readable on a light window.
    static let tertiary = Color(nsColor: .secondaryLabelColor)
    /// Off states and disabled glyphs.
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)
    /// A quiet fill inside a box (chips, fields, nested cards).
    static let card = Color.primary.opacity(0.06)
    /// A chip that is on.
    static let selected = Color.accentColor.opacity(0.16)

    static let waiting = Color(nsColor: .systemOrange)
    static let done = Color(nsColor: .systemGreen)
    static let failed = Color(nsColor: .systemRed)
    static let idle = Color(nsColor: .tertiaryLabelColor)

    // Boxes
    static let boxRadius: CGFloat = 10
    static let boxFill = Color.primary.opacity(0.035)
    static let boxStroke = Color.primary.opacity(0.07)
    static let boxPadding = EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14)
    /// Space between the rows of a section (each row pads itself too).
    static let rowSpacing: CGFloat = 4
}

// MARK: Chrome

/// Where a shared control is drawn: the notch (white on black, custom) or the Settings window
/// (system controls). The window's root sets `.window`.
enum SettingsChrome: Sendable { case notch, window }

private struct SettingsChromeKey: EnvironmentKey {
    static let defaultValue = SettingsChrome.notch
}

extension EnvironmentValues {
    var settingsChrome: SettingsChrome {
        get { self[SettingsChromeKey.self] }
        set { self[SettingsChromeKey.self] = newValue }
    }
}

// MARK: Boxes and their separators

/// What a box draws a separator above: every row after the first, except right under a group
/// title. Rows report their frame; the box draws the lines (no row knows its neighbours).
struct SettingsRowMark: Equatable {
    var bounds: Anchor<CGRect>
    var isTitle: Bool
}

struct SettingsRowMarks: PreferenceKey {
    static let defaultValue: [SettingsRowMark] = []
    static func reduce(value: inout [SettingsRowMark], nextValue: () -> [SettingsRowMark]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// A row of a settings box: the box draws a separator above it.
    func settingsRow(title: Bool = false) -> some View {
        anchorPreference(key: SettingsRowMarks.self, value: .bounds) { [SettingsRowMark(bounds: $0, isTitle: title)] }
    }
}

/// A grouped box, System Settings style, with separators between its rows.
struct SettingsBox<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsStyle.boxPadding)
            .overlayPreferenceValue(SettingsRowMarks.self) { marks in
                GeometryReader { geo in
                    let rects = marks.map { (geo[$0.bounds], $0.isTitle) }.sorted { $0.0.minY < $1.0.minY }
                    ForEach(Array(rects.enumerated()), id: \.offset) { i, item in
                        // Nothing above the first row, nor between a group title and its first row.
                        if i > 0, !rects[i - 1].1, item.0.minY - rects[i - 1].0.minY > 1 {
                            Rectangle()
                                .fill(SettingsStyle.hairline)
                                .frame(width: max(0, geo.size.width - SettingsStyle.boxPadding.leading - SettingsStyle.boxPadding.trailing),
                                       height: 1 / max(1, NSScreen.main?.backingScaleFactor ?? 2))
                                .position(x: geo.size.width / 2, y: item.0.minY - SettingsStyle.rowSpacing / 2)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            // A box inside a box keeps its rows to itself.
            .transformPreference(SettingsRowMarks.self) { $0 = [] }
            .background(RoundedRectangle(cornerRadius: SettingsStyle.boxRadius, style: .continuous).fill(SettingsStyle.boxFill))
            .overlay(RoundedRectangle(cornerRadius: SettingsStyle.boxRadius, style: .continuous)
                .strokeBorder(SettingsStyle.boxStroke, lineWidth: 1))
    }
}

/// A box with an optional header above it and a footer note under it.
struct SettingsSection<Content: View, Trailing: View>: View {
    let header: String?
    let footer: String?
    let trailing: Trailing
    let content: Content

    init(_ header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.header = header; self.footer = footer; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if header != nil || !(trailing is EmptyView) {
                HStack(alignment: .firstTextBaseline) {
                    if let header {
                        Text(verbatim: header)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SettingsStyle.primary)
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.horizontal, 4)
            }
            SettingsBox { content }
            if let footer {
                Text(verbatim: footer)
                    .font(SettingsStyle.font(.xs))
                    .foregroundStyle(SettingsStyle.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// The coloured square behind a page's symbol (sidebar rows, module headers).
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20
    var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(dimmed ? Color(nsColor: .systemGray) : tint)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolVariant(.fill)
            )
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.6 : 1)
    }
}
