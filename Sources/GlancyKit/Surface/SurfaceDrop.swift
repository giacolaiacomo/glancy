import AppKit

/// A module that takes content dragged onto the notch (the Shelf). The surface's hosting view
/// forwards its drag-destination calls here; with no target installed it behaves as before.
@MainActor
public protocol SurfaceDropTarget: AnyObject {
    var dropTypes: [NSPasteboard.PasteboardType] { get }
    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation
    func dragExited()
    func performDrop(_ info: NSDraggingInfo) -> Bool
}

@MainActor
public enum SurfaceDrop {
    /// Installed by the Shelf in `start`, removed in `stop`.
    public static weak var target: (any SurfaceDropTarget)? {
        didSet { NotificationCenter.default.post(name: changed, object: nil) }
    }
    static let changed = Notification.Name("ai.glancy.surfaceDropTargetChanged")
}
