import SwiftUI

/// The notch silhouette: concave "ears" where it meets the top edge, straight sides, convex bottom
/// corners. The rect includes the ears, so at the very top the shape spans the full width and the
/// body is inset by `topRadius` on each side. Both radii animate.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat

    public init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topRadius = topRadius; self.bottomRadius = bottomRadius
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    public func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        // Circular-arc approximation constant for a quarter circle with a cubic Bézier.
        let k: CGFloat = 0.5523
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left ear: concave quarter curve from the top edge down into the side.
        p.addCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                   control1: CGPoint(x: rect.minX + t * k, y: rect.minY),
                   control2: CGPoint(x: rect.minX + t, y: rect.minY + t * (1 - k)))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        // Bottom-left convex corner.
        p.addCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                   control1: CGPoint(x: rect.minX + t, y: rect.maxY - b * (1 - k)),
                   control2: CGPoint(x: rect.minX + t + b * (1 - k), y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        // Bottom-right convex corner.
        p.addCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                   control1: CGPoint(x: rect.maxX - t - b * (1 - k), y: rect.maxY),
                   control2: CGPoint(x: rect.maxX - t, y: rect.maxY - b * (1 - k)))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        // Right ear.
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                   control1: CGPoint(x: rect.maxX - t, y: rect.minY + t * (1 - k)),
                   control2: CGPoint(x: rect.maxX - t * k, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
