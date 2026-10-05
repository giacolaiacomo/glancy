import CoreFoundation
import Foundation

/// Playback commands, in-process. Reading MediaRemote is blocked for unentitled apps since macOS
/// 15.4, sending commands is not (RESEARCH Technical §3). Loaded lazily, on the first command.
@MainActor
enum MediaRemoteCommands {
    enum Command: UInt32 {
        case play = 0, pause = 1, toggle = 2, next = 4, previous = 5
    }

    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias SetElapsedFn = @convention(c) (Double) -> Void

    private static var loaded = false
    private static var sendFn: SendFn?
    private static var setElapsedFn: SetElapsedFn?

    private static func load() {
        guard !loaded else { return }
        loaded = true
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url) else { return }
        if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            sendFn = unsafeBitCast(p, to: SendFn.self)
        }
        if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSetElapsedTime" as CFString) {
            setElapsedFn = unsafeBitCast(p, to: SetElapsedFn.self)
        }
    }

    @discardableResult
    static func send(_ command: Command) -> Bool {
        load()
        return sendFn?(command.rawValue, nil) ?? false
    }

    static func seek(to seconds: TimeInterval) {
        load()
        setElapsedFn?(max(0, seconds))
    }
}

extension MediaRemoteCommands {
    /// Asks MediaRemote for its now-playing notifications. Reading is blocked for us, but if the
    /// "is playing did change" notification still arrives it is a free trigger to restart the
    /// adapter stream. Best effort: nothing breaks if it never fires.
    static let isPlayingDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
    static let appDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")

    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    static func registerForNotifications() {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url),
              let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString)
        else { return }
        unsafeBitCast(p, to: RegisterFn.self)(DispatchQueue.main)
    }
}
