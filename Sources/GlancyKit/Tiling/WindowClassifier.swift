// Tiling — which AX windows are real windows worth tiling. Pure: works on a snapshot of the
// attributes, so it is testable without Accessibility.
//
// Heuristics adapted from AeroSpace's `AxUiElementWindowType.swift` (MIT, see NOTICE.md):
// a window needs window buttons or the standard subrole; it is a dialog when its subrole is not
// standard or its fullscreen button is missing/disabled (with exclusions for apps that hide it).
// Loop's level filter (`[normal, popUpMenu)`) is applied to every app. AeroSpace's warning holds:
// many windows have no title at creation, so the title is never used to classify; a nil/empty
// title only marks the window provisional (Amethyst).

import CoreGraphics

public enum WindowKind: String, Sendable, Equatable {
    case tile, dialog, popup
}

/// What the classifier needs to know about a window, read once when the window is first seen.
public struct WindowTraits: Sendable, Equatable {
    public var bundleID: String?
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var hasCloseButton = false
    public var hasMinimizeButton = false
    public var hasZoomButton = false
    public var hasFullscreenButton = false
    /// nil = no button (or unknown).
    public var fullscreenButtonEnabled: Bool?
    public var closeButtonEnabled: Bool?
    public var minimizeButtonEnabled: Bool?
    public var isFocused = false
    public var isMain = false
    /// From CGWindowList (kCGWindowLayer); nil when the window is not on screen.
    public var windowLevel: Int?
    public var isRegularApp = true

    public init(bundleID: String? = nil, role: String? = "AXWindow", subrole: String? = nil) {
        self.bundleID = bundleID; self.role = role; self.subrole = subrole
    }
}

public enum WindowClassifier {
    static let standardSubrole = "AXStandardWindow"
    static let dialogSubrole = "AXDialog"
    static let floatingSubrole = "AXFloatingWindow"
    /// CGWindowLevelForKey(.popUpMenuWindow).
    static let popUpMenuLevel = 101

    /// Apps whose windows legitimately lack an enabled fullscreen button (AeroSpace's list).
    static let noFullscreenButtonApps: Set<String> = [
        "org.gimp.gimp-2.10", "com.google.Chrome", "com.apple.ActivityMonitor", "org.alacritty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.qutebrowser.qutebrowser",
        "com.googlecode.iterm2", "org.gnu.Emacs", "com.microsoft.VSCode", "com.vscodium",
        "com.valvesoftware.steam.helper",
    ]
    static let firefoxFamily: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
    ]

    public static func classify(_ t: WindowTraits) -> WindowKind {
        isWindow(t) ? (isDialog(t) ? .dialog : .tile) : .popup
    }

    static func isWindow(_ t: WindowTraits) -> Bool {
        guard t.role == nil || t.role == "AXWindow" else { return false }
        if let level = t.windowLevel, level < 0 || level >= popUpMenuLevel { return false }
        let id = t.bundleID
        if id == "com.mitchellh.ghostty", t.identifier == "com.mitchellh.ghostty.quickTerminal" { return false }
        if id == "com.apple.dt.Xcode", t.identifier == "open_quickly" { return false }
        if id == "com.googlecode.iterm2", !t.hasFullscreenButton { return false }
        if !t.isRegularApp, !t.hasCloseButton { return false }
        if id == "org.gnu.Emacs", t.subrole == floatingSubrole { return false }
        let hasButtons = t.hasCloseButton || t.hasFullscreenButton || t.hasZoomButton || t.hasMinimizeButton
        if !hasButtons, !t.isFocused, !t.isMain, t.subrole != standardSubrole { return false }
        if let id, firefoxFamily.contains(id) { return true }
        return t.subrole == standardSubrole || t.subrole == dialogSubrole || t.subrole == floatingSubrole
            || (id == "com.apple.finder" && t.subrole == "Quick Look")
    }

    static func isDialog(_ t: WindowTraits) -> Bool {
        let id = t.bundleID
        if id == "com.1password.1password", (t.windowLevel ?? 0) != 0 { return true }
        if id == "com.apple.iphonesimulator" || id == "com.apple.PhotoBooth" { return true }
        if t.subrole != standardSubrole, id != "org.qutebrowser.qutebrowser" { return true }
        if let id, firefoxFamily.contains(id), t.minimizeButtonEnabled != true { return true }
        if id == "com.mitchellh.ghostty" {
            return t.fullscreenButtonEnabled != true && t.closeButtonEnabled == true
        }
        if t.fullscreenButtonEnabled != true {
            if let id, noFullscreenButtonApps.contains(id) { return false }
            if let id, id.hasPrefix("com.microsoft.VSCode") { return false }
            return true
        }
        return false
    }
}
