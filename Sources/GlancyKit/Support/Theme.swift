import SwiftUI

// The single design vocabulary (SPEC §2 "Look"). Views use these, never ad-hoc values.

public enum Theme {
    // Shape
    public static let closedTopRadius: CGFloat = 6
    public static let closedBottomRadius: CGFloat = 14
    public static let openTopRadius: CGFloat = 19
    public static let openBottomRadius: CGFloat = 24

    // Sizes (points)
    public static let expandedSize = CGSize(width: 680, height: 210)   // 13 icons at full 30 pt slots beside a 185 pt notch
    public static let wingMaxWidth: CGFloat = 120
    public static let peekGrow = CGSize(width: 12, height: 6)
    public static let peekEventDrop: CGFloat = 32
    public static let hotZoneBelow: CGFloat = 4
    public static let panelPadding: CGFloat = 14

    // Motion — one family, nowhere else
    public static let open = Animation.spring(response: 0.42, dampingFraction: 0.82)
    public static let close = Animation.spring(response: 0.45, dampingFraction: 1.0)
    public static let peek = Animation.interactiveSpring(response: 0.32, dampingFraction: 0.86)

    // Type scale
    public static func font(_ size: Size, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue, weight: weight)
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
