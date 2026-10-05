import CoreGraphics
import Foundation
import ImageIO

/// Artwork decoding, off-main. Never decodes at full resolution: ImageIO builds a thumbnail
/// straight from the compressed data (boring.notch #1427 decoded full size for its colour).
public enum Artwork {
    /// Largest artwork on screen is the Media tab's (148 pt) → ~2× for Retina.
    public static let maxPixelSize = 300

    public struct Decoded: @unchecked Sendable {  // CGImage is immutable
        public let image: CGImage
        public let tint: RGB
    }

    public struct RGB: Equatable, Sendable {
        public var r: Double, g: Double, b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    }

    public static func decode(_ data: Data, maxPixelSize: Int = Artwork.maxPixelSize) -> Decoded? {
        guard let image = thumbnail(data, maxPixelSize: maxPixelSize) else { return nil }
        let avg = thumbnail(data, maxPixelSize: 16).flatMap(averageColor) ?? averageColor(image)
        return Decoded(image: image, tint: legibleTint(avg ?? RGB(r: 1, g: 1, b: 1)))
    }

    /// `CGImageSourceCreateThumbnailAtIndex` at `maxPixelSize` on the long side.
    public static func thumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }

    /// Mean colour, drawn into a 16×16 sRGB bitmap (cheap whatever the input).
    public static func averageColor(_ image: CGImage) -> RGB? {
        let side = 16
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]); a += Double(px[i + 3])
        }
        guard a > 0 else { return nil }
        // Premultiplied: dividing by total alpha un-premultiplies the mean.
        return RGB(r: r / a, g: g / a, b: b / a)
    }

    /// The average colour, nudged so it reads on black: not too dark, not neon.
    public static func legibleTint(_ c: RGB) -> RGB {
        var (h, s, v) = hsv(c)
        v = max(v, 0.72)
        s = min(s, 0.75)
        if s < 0.08 { s = 0 }  // greys stay grey (white-ish), no tinted mud
        return rgb(h: h, s: s, v: v)
    }

    static func hsv(_ c: RGB) -> (Double, Double, Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.g { h = (c.b - c.r) / d + 2 }
            else { h = (c.r - c.g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    static func rgb(h: Double, s: Double, v: Double) -> RGB {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }
}
