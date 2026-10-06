import Foundation

/// Hands memory back to macOS once the panel has closed. While the panel is open SwiftUI, text and
/// symbol rendering fill malloc's pages; once their objects are freed the pages stay dirty and keep
/// counting in Glancy's footprint until something returns them. `run()` lets modules drop what
/// they cache for the open panel, then returns every free page to the system
/// (`malloc_zone_pressure_relief`). Scheduled once, a few seconds after a collapse, by
/// `SurfaceManager` (cancelled if the panel reopens first), and after heavy one-off work.
@MainActor
public enum MemoryRelief {
    private static var hooks: [(owner: ObjectIdentifier, purge: @MainActor () -> Void)] = []
    /// Runs so far and bytes returned by the last one (tests, the lab).
    public private(set) static var runs = 0
    public private(set) static var lastReleased = 0

    /// `purge` drops what `owner` keeps only for the open panel (rebuilt lazily). One per owner.
    public static func register(_ owner: AnyObject, purge: @escaping @MainActor () -> Void) {
        let id = ObjectIdentifier(owner)
        hooks.removeAll { $0.owner == id }
        hooks.append((id, purge))
    }

    public static func unregister(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        hooks.removeAll { $0.owner == id }
    }

    static var hookCount: Int { hooks.count }

    /// Purges the registered caches, then returns free malloc pages to the system.
    @discardableResult
    public static func run() -> Int {
        for h in hooks { h.purge() }
        URLCache.shared.removeAllCachedResponses()
        runs += 1
        lastReleased = Int(malloc_zone_pressure_relief(nil, 0))
        if Lab.isActive {
            print(String(format: "lab: relief released %.1f MB", Double(lastReleased) / 1_048_576))
            fflush(stdout)
        }
        return lastReleased
    }
}
