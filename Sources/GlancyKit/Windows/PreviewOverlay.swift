// Windows — the preview on the real screen (Loop's approach, RESEARCH §2.6): a borderless,
// non-activating, mouse-transparent panel at `.screenSaver − 1` on every Space, drawing the
// planned frames as soft rounded rects that spring from one preview to the next. It exists only
// while something is previewed: created on the first `show`, destroyed after the fade-out.

import AppKit
import SwiftUI

@MainActor @Observable
final class OverlayState {
    struct Box: Identifiable, Equatable {
        let id: CGWindowID
        /// Local to the overlay (SwiftUI, y down).
        var rect: CGRect
        var title: String
        var bundleID: String?
        /// The window a swap would displace: drawn quieter.
        var secondary: Bool
        /// The selection's pick order.
        var number: Int? = nil
    }
    var boxes: [Box] = []
    /// A window hovered in the list: its current frame, outline only.
    var highlight: Box?
    var shown = false
}

@MainActor
final class PreviewOverlay {
    private var panel: NSPanel?
    private let state = OverlayState()
    private var displayFrame: CGRect = .zero
    private var teardown: Task<Void, Never>?

    /// Draws `plan` on `display` (with `numbers` on its boxes) and outlines `highlight` (a
    /// window's current frame); nothing to draw hides.
    func show(_ plan: ArrangePlan?, on display: Display?, highlight: TrackedWindow? = nil,
              numbers: [CGWindowID: Int] = [:], names: (CGWindowID) -> (String, String?)) {
        let plan = plan.flatMap { $0.moves.isEmpty ? nil : $0 }
        guard let display, plan != nil || highlight != nil else { hide(); return }
        teardown?.cancel(); teardown = nil
        let panel = self.panel ?? makePanel()
        if displayFrame != display.frame {
            displayFrame = display.frame
            panel.setFrame(display.frame, display: false)
        }
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX - display.frame.minX, y: display.frame.maxY - r.maxY, width: r.width, height: r.height)
        }
        let swap = plan?.kind == .swap
        let boxes = (plan?.moves ?? []).enumerated().map { i, m in
            let n = names(m.windowID)
            return OverlayState.Box(id: m.windowID, rect: local(m.to), title: n.0, bundleID: n.1, secondary: swap && i > 0,
                                    number: numbers[m.windowID])
        }
        let outline = highlight.map {
            OverlayState.Box(id: $0.id, rect: local($0.frame), title: $0.appName, bundleID: $0.bundleID, secondary: false)
        }
        let appearing = !state.shown
        if appearing {
            // New boxes appear in place (scale + fade), later ones spring to their new frames.
            state.boxes = boxes
            state.highlight = outline
            withAnimation(.easeOut(duration: 0.16)) { state.shown = true }
        } else {
            if boxes != state.boxes { withAnimation(Theme.peek) { state.boxes = boxes } }
            if outline != state.highlight { state.highlight = outline }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        guard panel != nil, teardown == nil else { return }
        withAnimation(.easeIn(duration: 0.14)) { state.shown = false }
        teardown = Task { [weak self] in
            try? await Delay.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.destroy()
        }
    }

    /// Immediately, without the fade (module stop).
    func destroy() {
        teardown?.cancel(); teardown = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        state.boxes = []
        state.highlight = nil
        state.shown = false
        displayFrame = .zero
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        // Follows the app's "hidden from screen recordings" setting (default on).
        let hidden = UserDefaults.standard.object(forKey: "hideFromCapture") as? Bool ?? true
        p.sharingType = hidden ? .none : .readOnly
        p.contentView = NSHostingView(rootView: OverlayView(state: state))
        panel = p
        return p
    }
}

/// Windows' accent: a cool blue, used for the target, the preview and the selection.
enum WindowsStyle {
    static let accent = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let swap = Color(red: 1.00, green: 0.72, blue: 0.24)
}

private struct OverlayView: View {
    let state: OverlayState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(state.boxes) { box in
                let tint = box.secondary ? WindowsStyle.swap : WindowsStyle.accent
                ZStack {
                    RoundedRectangle(cornerRadius: 14.ui, style: .continuous)
                        .fill(tint.opacity(box.secondary ? 0.10 : 0.16))
                    RoundedRectangle(cornerRadius: 14.ui, style: .continuous)
                        .strokeBorder(tint.opacity(0.75), lineWidth: 2.ui)
                    OverlayLabel(title: box.title, bundleID: box.bundleID, number: box.number)
                }
                .frame(width: box.rect.width, height: box.rect.height)
                .offset(x: box.rect.minX, y: box.rect.minY)
            }
            // The list row under the pointer: where that window is now, outline only.
            if let h = state.highlight {
                RoundedRectangle(cornerRadius: 12.ui, style: .continuous)
                    .strokeBorder(WindowsStyle.accent, lineWidth: 3.ui)
                    .frame(width: h.rect.width, height: h.rect.height)
                    .offset(x: h.rect.minX, y: h.rect.minY)
            }
        }
        .opacity(state.shown ? 1 : 0)
        .scaleEffect(state.shown ? 1 : 0.985)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct OverlayLabel: View {
    let title: String
    let bundleID: String?
    var number: Int?

    var body: some View {
        HStack(spacing: 8.ui) {
            if let number { OrderBadge(number: number, size: 26.ui) }
            if let icon = AppIcons.icon(bundleID) {
                Image(nsImage: icon).resizable().frame(width: 28.ui, height: 28.ui)
            }
            Text(verbatim: title)
                .font(.system(size: 15.ui, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14.ui).padding(.vertical, 8.ui)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// App icons by bundle ID, for the map and the overlay. Cleared when the tab closes.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let i = cache[bundleID] { return i }
        guard cache.count < 64, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }

    static func clear() { cache.removeAll() }
}
