import Observation
import SwiftUI

// The single design vocabulary (SPEC §2 "Look"). Views use these, never ad-hoc values.
//
// Size (Settings → General): every point a view lays out goes through the chosen factor — fonts,
// symbols, paddings, radii, the panel itself — by `Theme.font`, the metrics below and `N.ui` on a
// literal. The metrics are scaled, not the drawing: a `.scaleEffect` resamples text drawn at the
// normal size (measured: as soft as a bitmap), a bigger font is drawn sharp.

public enum Theme {
    /// The metrics at the normal size. Layout code that knows its display's factor scales these
    /// itself (`SurfaceLayout`); views use the scaled accessors below.
    public enum Base {
        public static let closedTopRadius: CGFloat = 6
        public static let closedBottomRadius: CGFloat = 14
        public static let openTopRadius: CGFloat = 19
        public static let openBottomRadius: CGFloat = 24
        public static let expandedSize = CGSize(width: 680, height: 210)   // 13 icons at full 30 pt slots beside a 185 pt notch
        public static let wingMaxWidth: CGFloat = 120
        public static let peekGrow = CGSize(width: 12, height: 6)
        public static let peekEventDrop: CGFloat = 32
        public static let panelPadding: CGFloat = 14
    }

    // Shape
    public static var closedTopRadius: CGFloat { Base.closedTopRadius.ui }
    public static var closedBottomRadius: CGFloat { Base.closedBottomRadius.ui }
    public static var openTopRadius: CGFloat { Base.openTopRadius.ui }
    public static var openBottomRadius: CGFloat { Base.openBottomRadius.ui }

    // Sizes (points, at the chosen size)
    public static var expandedSize: CGSize { CGSize(width: Base.expandedSize.width.ui, height: Base.expandedSize.height.ui) }
    public static var wingMaxWidth: CGFloat { Base.wingMaxWidth.ui }
    public static var peekGrow: CGSize { CGSize(width: Base.peekGrow.width.ui, height: Base.peekGrow.height.ui) }
    public static var peekEventDrop: CGFloat { Base.peekEventDrop.ui }
    /// The invisible strip under a collapsed shape that still counts as hovering it. Not scaled.
    public static let hotZoneBelow: CGFloat = 4
    public static var panelPadding: CGFloat { Base.panelPadding.ui }

    // Motion — one family, nowhere else
    public static let open = Animation.spring(response: 0.42, dampingFraction: 0.82)
    public static let close = Animation.spring(response: 0.45, dampingFraction: 1.0)
    public static let peek = Animation.interactiveSpring(response: 0.32, dampingFraction: 0.86)

    // Type scale
    public static func font(_ size: Size, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue.ui, weight: weight)
    }
    public enum Size: CGFloat { case xs = 10, s = 11, m = 12, l = 13, xl = 15 }

    // Ink on black
    public static let primary = Color.white.opacity(0.92)
    public static let secondary = Color.white.opacity(0.60)
    public static let tertiary = Color.white.opacity(0.35)
    public static let hairline = Color.white.opacity(0.10)
    public static let card = Color.white.opacity(0.06)

    // State colours (Agents and anything that reports a state)
    public static let working = Color.white.opacity(0.85)
    public static let waiting = Color(red: 1.00, green: 0.72, blue: 0.24)
    public static let done = Color(red: 0.36, green: 0.84, blue: 0.48)
    public static let failed = Color(red: 1.00, green: 0.38, blue: 0.36)
    public static let idle = Color.white.opacity(0.30)
}

// MARK: - Size

/// Settings → General → Size. Three steps only: each step is one more set of font sizes in the
/// glyph caches, and the size never animates through in-between ones.
public enum UISize: String, CaseIterable, Codable, Sendable {
    case normal, large, extraLarge

    public var factor: CGFloat {
        switch self {
        case .normal: 1
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }

    /// The largest size up to this one whose expanded panel (and its shadow) fits inside the visible
    /// area of every display in `screens`. Normal is the floor.
    public func fitting(_ screens: [ScreenInfo]) -> UISize {
        let steps = Self.allCases.filter { $0.factor <= factor }.sorted { $0.factor > $1.factor }
        return steps.first { s in screens.allSatisfy { s.fits($0) } } ?? .normal
    }

    /// The expanded panel at this size, shadow margin included, inside the display's visible area.
    public func fits(_ screen: ScreenInfo) -> Bool {
        let f = factor
        let w = UIScale.scaled(Theme.Base.expandedSize.width, by: f) + 2 * SurfaceLayout.shadowInset.width
        let h = UIScale.scaled(Theme.Base.expandedSize.height, by: f) + SurfaceLayout.shadowInset.height
        return w <= screen.visibleFrame.width && h <= screen.visibleFrame.height
    }
}

/// The size in use: the chosen one, or the largest that fits when the chosen one would overflow a
/// display. Observable, so every view that reads a scaled metric re-renders when it changes (live,
/// no relaunch); written on main by `SurfaceManager` only.
@Observable
public final class UIScale: @unchecked Sendable {
    public static let shared = UIScale()

    /// What the user chose.
    public private(set) var requested: UISize = .normal
    /// What is drawn (≤ requested).
    public private(set) var size: UISize = .normal
    public private(set) var factor: CGFloat = 1

    public init() {}

    /// The chosen size does not fit a display: `size` is smaller than `requested`.
    public var isLimited: Bool { size != requested }

    public func set(requested: UISize, effective: UISize) {
        if self.requested != requested { self.requested = requested }
        if size != effective {
            size = effective
            factor = effective.factor
        }
    }

    /// `v` at factor `f`, on the half-point grid (whole pixels at 2×). Factor 1 returns `v` as is.
    public static func scaled(_ v: CGFloat, by f: CGFloat) -> CGFloat {
        f == 1 ? v : (v * f * 2).rounded() / 2
    }
}

public extension BinaryInteger {
    /// This many points at the chosen size (Settings → General → Size).
    var ui: CGFloat { UIScale.scaled(CGFloat(self), by: UIScale.shared.factor) }
}

public extension Double {
    /// This many points at the chosen size (Settings → General → Size).
    var ui: CGFloat { UIScale.scaled(CGFloat(self), by: UIScale.shared.factor) }
}

public extension CGFloat {
    /// This many points at the chosen size (Settings → General → Size).
    var ui: CGFloat { UIScale.scaled(self, by: UIScale.shared.factor) }
}
