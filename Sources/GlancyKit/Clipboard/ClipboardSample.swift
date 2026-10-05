import AppKit

/// Synthetic history for the off-screen renderer (and `GLANCY_CLIPBOARD_SAMPLE=1`): renders never
/// show the user's real clipboard.
@MainActor
enum ClipboardSample {
    static func items(blobs: URL, now: Date = .now) -> [ClipItem] {
        try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let imageName = "sample.png"
        let imageURL = blobs.appendingPathComponent(imageName)
        if let png = sampleImage() { try? png.write(to: imageURL) }
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        var n = 0
        func item(_ kind: ClipKind, _ text: String, _ app: (String, String), _ age: TimeInterval, pinned: Bool = false,
                  files: [URL] = [], image: String? = nil, size: CGSize? = nil) -> ClipItem {
            n += 1
            return ClipItem(kind: kind, text: text, signature: "sample-\(n)", date: ago(age), pinned: pinned,
                            sourceBundleID: app.0, sourceName: app.1, imageBlob: image, imageSize: size, fileURLs: files)
        }
        let terminal = ("com.apple.Terminal", "Terminal")
        let safari = ("com.apple.Safari", "Safari")
        let notes = ("com.apple.Notes", "Notes")
        let preview = ("com.apple.Preview", "Preview")
        let finder = ("com.apple.finder", "Finder")
        let mail = ("com.apple.mail", "Mail")
        return [
            item(.text, "221B Baker Street, London NW1 6XE", notes, 9 * 86_400, pinned: true),
            item(.text, "IT60 X054 2811 1010 0000 0123 456", mail, 20 * 86_400, pinned: true),
            item(.text, "git rebase -i --autosquash origin/main && swift test --parallel", terminal, 25),
            item(.url, "https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)",
                 safari, 4 * 60),
            item(.image, "", preview, 22 * 60, image: imageName, size: CGSize(width: 512, height: 320)),
            item(.richText, "Notch review — the wings should never sit on status items; keep the close spring critically damped and the shadow only when expanded.",
                 notes, 2 * 3600 + 300),
            item(.files, "", finder, 5 * 3600, files: [URL(fileURLWithPath: "/Users/Shared/Design/glancy-icon.sketch"),
                                                   URL(fileURLWithPath: "/Users/Shared/Design/notch-states.pdf")]),
            item(.text, "Thanks Alex — Thursday at 10:30 works, I'll send the invite with the Zoom link.", mail, 26 * 3600),
        ]
    }

    /// A small gradient "screenshot" so the image row and preview have something real to draw.
    private static func sampleImage() -> Data? {
        let w = 512, h = 320
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [CGColor(red: 0.20, green: 0.24, blue: 0.52, alpha: 1), CGColor(red: 0.85, green: 0.45, blue: 0.40, alpha: 1)]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        let notch = CGPath(roundedRect: CGRect(x: 186, y: 262, width: 140, height: 40), cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.addPath(notch); ctx.fillPath()
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fill(CGRect(x: 40, y: 60, width: 300, height: 14))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.5))
        ctx.fill(CGRect(x: 40, y: 90, width: 200, height: 10))
        guard let img = ctx.makeImage() else { return nil }
        return ClipImage.encode(img, .png, quality: nil)
    }
}
