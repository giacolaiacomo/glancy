import AppKit
import ApplicationServices

/// Counts what an object holds that keeps the system calling it back: notification observer
/// tokens, event monitors, run-loop and dispatch sources / mach ports / AX observers, live tasks
/// and running child processes. Walks stored properties by reflection, into GlancyKit's own helper objects
/// (a module's watcher, tap, reader), never into the shared hub or settings.
///
/// Used by `--diagnose` (observers per module) and by tests: after `stop()` a module must hold
/// nothing that is still live.
public struct ResourceCensus: Equatable, Sendable, CustomStringConvertible {
    public var observers = 0
    public var monitors = 0
    public var sources = 0
    public var tasks = 0
    public var processes = 0

    public var total: Int { observers + monitors + sources + tasks + processes }

    public var description: String {
        "observers \(observers), monitors \(monitors), sources \(sources), tasks \(tasks), processes \(processes)"
    }

    /// Types that are shared or are pure state: never walked into.
    static let opaque: [String] = [
        "GlancyKit.ActivityHub", "GlancyKit.SurfaceContext", "GlancyKit.AppSettings", "GlancyKit.LaunchAtLogin",
    ]

    @MainActor public static func of(_ root: AnyObject, depth: Int = 4) -> ResourceCensus {
        var c = ResourceCensus()
        var seen = Set<ObjectIdentifier>([ObjectIdentifier(root)])
        c.walkChildren(of: root, depth: depth, seen: &seen)
        return c
    }

    private mutating func walkChildren(of value: Any, depth: Int, seen: inout Set<ObjectIdentifier>) {
        var mirror: Mirror? = Mirror(reflecting: value)
        while let m = mirror {
            for child in m.children { visit(child.value, depth: depth, seen: &seen) }
            mirror = m.superclassMirror
        }
    }

    private mutating func visit(_ value: Any, depth: Int, seen: inout Set<ObjectIdentifier>) {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            if let some = mirror.children.first { visit(some.value, depth: depth, seen: &seen) }
            return
        case .collection, .set, .dictionary, .tuple:
            // Big collections are data (sessions, items), not handles.
            guard mirror.children.count <= 256 else { return }
            for child in mirror.children { visit(child.value, depth: depth, seen: &seen) }
            return
        default:
            break
        }

        if let task = value as? Task<Void, Never> {
            if !task.isCancelled { tasks += 1 }
            return
        }
        let typeName = String(reflecting: type(of: value))
        if typeName.hasPrefix("Swift.Task<") { tasks += 1; return }
        if let p = value as? Process {
            if p.isRunning { processes += 1 }
            return
        }

        guard mirror.displayStyle == .class || mirror.displayStyle == .struct || mirror.displayStyle == .enum
                || type(of: value) is AnyClass else { return }

        if type(of: value) is AnyClass {
            let object = value as AnyObject
            let cls = NSStringFromClass(type(of: object))
            if cls == "__NSObserver" { observers += 1; return }
            if let source = object as? DispatchSourceProtocol, cls.hasPrefix("OS_dispatch_source") {
                if !source.isCancelled { sources += 1 }
                return
            }
            if cls.hasSuffix("EventObserver") || cls.hasSuffix("EventMonitor") { monitors += 1; return }
            if cls == "__NSCFType" {
                let id = CFGetTypeID(object as CFTypeRef)
                if id == CFRunLoopSourceGetTypeID() || id == CFMachPortGetTypeID() || id == AXObserverGetTypeID() {
                    sources += 1
                }
                return
            }
            guard typeName.hasPrefix("GlancyKit."), !Self.opaque.contains(typeName), !(value is any Actor),
                  depth > 0, seen.insert(ObjectIdentifier(object)).inserted else { return }
            walkChildren(of: value, depth: depth - 1, seen: &seen)
        } else if typeName.hasPrefix("GlancyKit."), depth > 0 {
            walkChildren(of: value, depth: depth - 1, seen: &seen)
        }
    }
}
