// Windows — the hotkeys, as a small settings model. Persisted next to the engine's config
// (`~/Library/Application Support/Glancy/windows.json`), decoded leniently so a file from another
// version never resets someone's bindings. Rebound from Settings → Windows; a binding with no
// modifiers is cleared (not registered).

import Carbon.HIToolbox
import Foundation

public struct WindowsHotkeys: Codable, Equatable, Sendable {
    static let ctrlOpt = UInt32(controlKey | optionKey)

    /// Auto-arrange the display under the pointer at once (the tab's Suggested layout); the same
    /// key with ⇧ added arranges only the front app's windows there. Undo with `undo`.
    public var autoArrange = Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: ctrlOpt)
    /// Opens the Windows tab with keyboard focus.
    public var open = Hotkey(keyCode: UInt32(kVK_Space), modifiers: ctrlOpt)
    public var leftHalf = Hotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOpt)
    public var rightHalf = Hotkey(keyCode: UInt32(kVK_RightArrow), modifiers: ctrlOpt)
    public var maximize = Hotkey(keyCode: UInt32(kVK_UpArrow), modifiers: ctrlOpt)
    public var restore = Hotkey(keyCode: UInt32(kVK_DownArrow), modifiers: ctrlOpt)
    public var fit = Hotkey(keyCode: UInt32(kVK_ANSI_F), modifiers: ctrlOpt)
    public var undo = Hotkey(keyCode: UInt32(kVK_ANSI_Z), modifiers: ctrlOpt)
    /// Arrange the display under the pointer, committed at once (undo with `undo`). The same key
    /// with ⇧ added arranges only the front app's windows there.
    public var arrangeBalanced = Hotkey(keyCode: UInt32(kVK_ANSI_B), modifiers: ctrlOpt)
    public var arrangeColumns = Hotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: ctrlOpt)
    public var arrangeRows = Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: ctrlOpt)
    public var arrangeMaster = Hotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: ctrlOpt)
    public var arrangeCells = Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: ctrlOpt)
    /// Master switch for all of the above.
    public var enabled = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowsHotkeys()
        autoArrange = c.lenient(.autoArrange, d.autoArrange)
        open = c.lenient(.open, d.open)
        leftHalf = c.lenient(.leftHalf, d.leftHalf)
        rightHalf = c.lenient(.rightHalf, d.rightHalf)
        maximize = c.lenient(.maximize, d.maximize)
        restore = c.lenient(.restore, d.restore)
        fit = c.lenient(.fit, d.fit)
        undo = c.lenient(.undo, d.undo)
        arrangeBalanced = c.lenient(.arrangeBalanced, d.arrangeBalanced)
        arrangeColumns = c.lenient(.arrangeColumns, d.arrangeColumns)
        arrangeRows = c.lenient(.arrangeRows, d.arrangeRows)
        arrangeMaster = c.lenient(.arrangeMaster, d.arrangeMaster)
        arrangeCells = c.lenient(.arrangeCells, d.arrangeCells)
        enabled = c.lenient(.enabled, true)
    }

    /// Every binding with what it does (nil action = open the tab).
    var bindings: [(DirectAction?, Hotkey)] {
        [(nil, open), (.leftHalf, leftHalf), (.rightHalf, rightHalf), (.maximize, maximize),
         (.restore, restore), (.fit, fit), (.undo, undo)]
    }

    /// The arrange shortcuts, one per strategy.
    var arrangeBindings: [(ArrangeStrategy, Hotkey)] {
        [(.balanced, arrangeBalanced), (.columns, arrangeColumns), (.rows, arrangeRows),
         (.masterStack, arrangeMaster), (.cells, arrangeCells)]
    }

    /// Every combination bound above (the ⇧ variants never shadow one of them).
    var allCombos: Set<Hotkey> { Set(bindings.map(\.1) + arrangeBindings.map(\.1) + [autoArrange]) }

    /// The ⇧ variant of an arrange shortcut (front app only); nil when it already holds ⇧ or is cleared.
    static func appVariant(_ h: Hotkey) -> Hotkey? {
        let shift = UInt32(shiftKey)
        guard h.modifiers != 0, h.modifiers & shift == 0 else { return nil }
        return Hotkey(keyCode: h.keyCode, modifiers: h.modifiers | shift)
    }

    public static var defaultURL: URL {
        TilingConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("windows.json")
    }

    public static func load(from url: URL = defaultURL) -> WindowsHotkeys {
        guard let data = try? Data(contentsOf: url) else { return WindowsHotkeys() }
        return (try? JSONDecoder().decode(WindowsHotkeys.self, from: data)) ?? WindowsHotkeys()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
