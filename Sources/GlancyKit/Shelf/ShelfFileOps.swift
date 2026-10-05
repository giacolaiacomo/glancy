import AppKit
import ImageIO
import UniformTypeIdentifiers

/// File work the shelf does for the user: zip archives and image conversions. Everything here is
/// nonisolated and runs off the main thread (the module calls it from detached tasks); outputs
/// never overwrite anything ("Archive.zip", "Archive 2.zip", …).
public enum ShelfFileOps {
    public enum OpError: Error, Equatable {
        case nothingToDo
        case toolFailed(Int32)
        case unreadableImage(String)
        case writeFailed(String)
    }

    // MARK: Names

    /// `folder/name` if free, otherwise "base 2.ext", "base 3.ext"… (Finder's rule).
    public static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Finder's naming: one item → "<name>.zip", several → "Archive.zip".
    public static func archiveName(for sources: [URL]) -> String {
        if sources.count == 1, let only = sources.first { return only.lastPathComponent + ".zip" }
        return "Archive.zip"
    }

    // MARK: Zip

    /// Zips `sources` into `folder` with `/usr/bin/ditto -c -k` (what Finder's Compress uses:
    /// keeps resource forks and extended attributes in `__MACOSX`). Several sources are cloned
    /// into a temporary folder first (APFS clones: no extra space) so the archive opens to the
    /// files themselves, like Finder's "Archive.zip". Blocking: call off main.
    public static func zip(_ sources: [URL], into folder: URL) throws -> URL {
        guard !sources.isEmpty else { throw OpError.nothingToDo }
        let out = uniqueURL(in: folder, name: archiveName(for: sources))
        if sources.count == 1 {
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", sources[0].path, out.path])
            return out
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("glancy-zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        for src in sources {
            let dest = uniqueURL(in: temp, name: src.lastPathComponent)
            try fm.copyItem(at: src, to: dest)
        }
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", temp.path, out.path])
        return out
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        ChildProcesses.register(p.processIdentifier)
        p.waitUntilExit()
        ChildProcesses.unregister(p.processIdentifier)
        guard p.terminationStatus == 0 else { throw OpError.toolFailed(p.terminationStatus) }
    }

    // MARK: Images

    public enum Conversion: String, Sendable, CaseIterable {
        /// HEIC / PNG / TIFF… → JPEG, full size.
        case jpeg
        /// Half the width and height, same format when it can be written (JPEG otherwise).
        case half
    }

    public static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && type != .pdf
    }

    /// Converts one image with ImageIO (orientation applied, colour profile kept). Blocking: call
    /// off main. Returns the new file, next to nothing else in `folder`.
    public static func convert(_ src: URL, _ conversion: Conversion, into folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw OpError.unreadableImage(src.lastPathComponent) }

        let base = src.deletingPathExtension().lastPathComponent
        let srcType = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) ?? .jpeg
        let outType: UTType
        let name: String
        let maxSide: Int
        switch conversion {
        case .jpeg:
            outType = .jpeg
            name = base + ".jpg"
            maxSide = max(width, height)
        case .half:
            let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(srcType.identifier)
            outType = writable ? srcType : .jpeg
            name = "\(base) 50%." + (outType.preferredFilenameExtension ?? "jpg")
            maxSide = max(1, max(width, height) / 2)
        }
        // A thumbnail at the full size is the cheapest way to get an upright, decoded image.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw OpError.unreadableImage(src.lastPathComponent) }

        let out = uniqueURL(in: folder, name: name)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, outType.identifier as CFString, 1, nil)
        else { throw OpError.writeFailed(out.lastPathComponent) }
        var outProps: [CFString: Any] = [:]
        if outType == .jpeg || outType == .heic { outProps[kCGImageDestinationLossyCompressionQuality] = 0.85 }
        // Keep the metadata, minus the orientation (already applied above).
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = props[key] { outProps[key] = v }
        }
        outProps[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(dest, image, outProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw OpError.writeFailed(out.lastPathComponent)
        }
        return out
    }

    /// Pixel size of an image file (tests and captions).
    public static func pixelSize(_ url: URL) -> CGSize? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Where a result goes: beside the first source when that folder is writable and is not one
    /// of Glancy's own staging folders; otherwise nil (the caller stages it on the shelf).
    public static func outputFolder(beside sources: [URL], staging: URL) -> URL? {
        guard let first = sources.first else { return nil }
        let folder = first.deletingLastPathComponent().standardizedFileURL
        if folder.path.hasPrefix(staging.standardizedFileURL.path + "/") || folder.path == staging.standardizedFileURL.path { return nil }
        return FileManager.default.isWritableFile(atPath: folder.path) ? folder : nil
    }
}
