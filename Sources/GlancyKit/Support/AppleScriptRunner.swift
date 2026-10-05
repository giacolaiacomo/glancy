import Foundation

/// Every `NSAppleScript` Glancy runs goes through here: one serial queue, never the main thread.
/// NSAppleScript is not thread-safe: Media (player fallback), Control (dark mode, Trash) and Notes
/// (send to Apple Notes) each used to run scripts on their own queue, so two could execute at once.
/// The first script for an app may show the Automation prompt and block until it is answered: that
/// wait happens here, never on main. `scripts/lint.sh` forbids `NSAppleScript(` anywhere else.
enum AppleScriptRunner {
    static let queue = DispatchQueue(label: "ai.glancy.applescript", qos: .userInitiated)

    /// Runs `source` and returns its result or the error dictionary. Call only on `queue`.
    static func execute(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (result, error)
    }

    /// Fire and forget.
    static func run(_ source: String) {
        queue.async { _ = execute(source) }
    }
}
