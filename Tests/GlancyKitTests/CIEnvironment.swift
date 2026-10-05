import Foundation

/// GitHub Actions (and most CI) sets `CI=true`. Tests that read this Mac's real state (TCC,
/// MediaRemote) or depend on tight main-thread timing are skipped there; they still run locally.
enum CI {
    static let isCI = ProcessInfo.processInfo.environment["CI"] != nil
}
