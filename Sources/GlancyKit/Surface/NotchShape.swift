import SwiftUI

/// The notch silhouette: concave "ears" where it meets the top edge, straight sides, convex bottom
/// corners. The rect includes the ears, so at the very top the shape spans the full width and the
/// body is inset by `topRadius` on each side. Both radii animate.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    /// Drop-downs: the sides pulled in by these amounts within the top `bandHeight` points, then a
    /// pair of curves out to the full width below (see `SurfaceLayout.bandInsetLeft`).
    public var bandInsetLeft: CGFloat
    public var bandInsetRight: CGFloat
    public var bandHeight: CGFloat

    public init(topRadius: CGFloat, bottomRadius: CGFloat,
                bandInsetLeft: CGFloat = 0, bandInsetRight: CGFloat = 0, bandHeight: CGFloat = 0) {
        self.topRadius = topRadius; self.bottomRadius = bottomRadius
        self.bandInsetLeft = bandInsetLeft; self.bandInsetRight = bandInsetRight; self.bandHeight = bandHeight
    }

    public var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), AnimatablePair(bandInsetLeft, bandInsetRight)) }
        set {
            topRadius = newValue.first.first; bottomRadius = newValue.first.second
            bandInsetLeft = newValue.second.first; bandInsetRight = newValue.second.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        // Circular-arc approximation constant for a quarter circle with a cubic Bézier.
        let k: CGFloat = 0.5523
        let s = SurfaceLayout.bandShoulder
        // A band step needs room for its two curves above the bottom corner.
        let bandOK = bandHeight > t + s && bandHeight + s + b <= rect.height
        let il = bandOK && bandInsetLeft > 2 * s ? min(bandInsetLeft, rect.width / 2 - t) : 0
        let ir = bandOK && bandInsetRight > 2 * s ? min(bandInsetRight, rect.width / 2 - t) : 0
        let y = rect.minY + bandHeight
        var p = Path()
        let lx = rect.minX + il
        p.move(to: CGPoint(x: lx, y: rect.minY))
        // Left ear: concave quarter curve from the top edge down into the side.
        p.addCurve(to: CGPoint(x: lx + t, y: rect.minY + t),
                   control1: CGPoint(x: lx + t * k, y: rect.minY),
                   control2: CGPoint(x: lx + t, y: rect.minY + t * (1 - k)))
        if il > 0 {
            // Down the band, a concave curve out, along under the menu bar, a convex curve down.
            p.addLine(to: CGPoint(x: lx + t, y: y - s))
            p.addCurve(to: CGPoint(x: lx + t - s, y: y),
                       control1: CGPoint(x: lx + t, y: y - s * (1 - k)),
                       control2: CGPoint(x: lx + t - s * (1 - k), y: y))
            p.addLine(to: CGPoint(x: rect.minX + t + s, y: y))
            p.addCurve(to: CGPoint(x: rect.minX + t, y: y + s),
                       control1: CGPoint(x: rect.minX + t + s * (1 - k), y: y),
                       control2: CGPoint(x: rect.minX + t, y: y + s * (1 - k)))
        }
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
        let rx = rect.maxX - ir
        if ir > 0 {
            p.addLine(to: CGPoint(x: rect.maxX - t, y: y + s))
            p.addCurve(to: CGPoint(x: rect.maxX - t - s, y: y),
                       control1: CGPoint(x: rect.maxX - t, y: y + s * (1 - k)),
                       control2: CGPoint(x: rect.maxX - t - s * (1 - k), y: y))
            p.addLine(to: CGPoint(x: rx - t + s, y: y))
            p.addCurve(to: CGPoint(x: rx - t, y: y - s),
                       control1: CGPoint(x: rx - t + s * (1 - k), y: y),
                       control2: CGPoint(x: rx - t, y: y - s * (1 - k)))
        }
        p.addLine(to: CGPoint(x: rx - t, y: rect.minY + t))
        // Right ear.
        p.addCurve(to: CGPoint(x: rx, y: rect.minY),
                   control1: CGPoint(x: rx - t, y: rect.minY + t * (1 - k)),
                   control2: CGPoint(x: rx - t * k, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
