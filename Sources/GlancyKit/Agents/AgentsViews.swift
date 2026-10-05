import SwiftUI

// Agents surfaces: wings, peek, the board (tab) and the Home card. Theme only.

extension AgentState {
    var color: Color {
        switch self {
        case .waiting: Theme.waiting
        case .working: Theme.working
        case .done: Theme.done
        case .failed: Theme.failed
        case .idle, .ended: Theme.idle
        }
    }
}

extension AgentDot {
    /// done is green only while fresh (2'), then reads as idle; failed stays red until stale.
    var color: Color { state == .done && !fresh ? Theme.idle : state.color }
}

/// A state dot. A working dot breathes with one 1.6 s animation, only while `pulsing`.
struct AgentStateDot: View {
    let color: Color
    let pulsing: Bool
    var size: CGFloat = 6
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.4 : 1)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .id(pulsing)   // turning the pulse off rebuilds the dot: no animation left running
    }
}

// MARK: Wings

struct AgentsWingLeft: View {
    let model: AgentsModel
    static let maxDots = 8

    var body: some View {
        let dots = model.dots
        let shown = dots.prefix(dots.count > Self.maxDots ? Self.maxDots - 1 : Self.maxDots)
        HStack(spacing: 4) {
            ForEach(shown) { d in
                AgentStateDot(color: d.color, pulsing: model.pulse && d.state == .working)
            }
            if dots.count > shown.count {
                Text("+\(dots.count - shown.count)")
                    .font(Theme.font(.xs, .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        }
        .fixedSize()
    }
}

struct AgentsWingRight: View {
    let model: AgentsModel

    var body: some View {
        let s = model.summary
        if let state = s.state {
            Text(AgentsText.count(s.count, state))
                .font(Theme.font(.s, .medium).monospacedDigit())
                .foregroundStyle(state == .working ? Theme.secondary : state.color)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: Peek

struct AgentsPeekView: View {
    let text: String
    let detail: String?
    let state: AgentState
    /// "Show": jump to the session's terminal (no tiling). nil = no action.
    var show: (@MainActor () -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            AgentStateDot(color: state.color, pulsing: false, size: 7)
            Text(text)
                .font(Theme.font(.m, .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            if let detail {
                Text("· \(detail)")
                    .font(Theme.font(.m).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            if let show {
                Text(AgentsText.t("Show"))
                    .font(Theme.font(.s, .semibold))
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                    .overlay(PeekClickTarget(action: show))
                    .accessibilityAddTraits(.isButton)
            }
        }
        .fixedSize()
    }
}

/// The collapsed surface turns every click into "open the panel" before SwiftUI sees it. A real
/// NSView over the Show button receives its own clicks (the window hit-tests to it first), so the
/// button acts while the rest of the peek still opens the panel.
private struct PeekClickTarget: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView(action: action) }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }

    final class ClickView: NSView {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

// MARK: Board (Agents tab)

struct AgentsBoard: View {
    let model: AgentsModel

    var body: some View {
        let rows = model.sessions
        if rows.isEmpty {
            AgentsEmptyState(loaded: model.loaded)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                AgentsBoardHeader(rows: rows, model: model)
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        ForEach(rows, id: \.rowID) { s in
                            AgentRow(session: s, pulsing: model.pulse,
                                     note: model.jumpNote?.rowID == s.rowID ? model.jumpNote?.text : nil,
                                     tiling: model.tilingAvailability) {
                                // ⌥-click: jump and tile into the focused cell.
                                if NSEvent.modifierFlags.contains(.option) {
                                    model.jumpAndTile(rowID: s.rowID)
                                } else {
                                    model.jump(to: s.rowID)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct AgentsBoardHeader: View {
    let rows: [AgentSession]
    let model: AgentsModel

    var body: some View {
        let live = rows.filter(\.isLive)
        let counts = [AgentState.waiting, .working, .done, .failed].compactMap { st -> (AgentState, Int)? in
            let n = live.filter { $0.state == st }.count
            return n > 0 ? (st, n) : nil
        }
        HStack(spacing: 10) {
            Text(AgentsText.live(live.count))
                .foregroundStyle(Theme.secondary)
            ForEach(counts, id: \.0) { st, n in
                HStack(spacing: 4) {
                    Circle().fill(st.color).frame(width: 5, height: 5)
                    Text(AgentsText.count(n, st)).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 8)
            AgentsTilingControls(model: model, liveCount: live.count)
        }
        .font(Theme.font(.xs, .medium).monospacedDigit())
        .padding(.horizontal, 8)
        .frame(height: 22)
    }
}

/// "Lay out sessions" and what follows it: the preview to confirm (Apply / ⏎, Cancel / Esc), the
/// outcome line, Undo (⌘Z). Disabled with a one-line reason without Accessibility; hidden when the
/// Windows module is off. Shared by the Agents tab header and the Home card.
struct AgentsTilingControls: View {
    let model: AgentsModel
    let liveCount: Int
    /// Home: only the preview / outcome states (the action lives in the overflow menu).
    var compact = false

    var body: some View {
        let availability = model.tilingAvailability
        HStack(spacing: 6) {
            if availability != .unavailable {
                if let p = model.layoutPreview {
                    Text(AgentsText.previewing(p.count))
                        .font(Theme.font(.xs, .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    WindowsPillButton(text: AgentsText.t("Cancel"), symbol: nil, prominent: false, enabled: true) {
                        model.cancelLayoutPreview()
                    }
                    .help(AgentsText.t("Esc"))
                    WindowsPillButton(text: AgentsText.t("Apply"), symbol: "return", prominent: true, enabled: !model.tilingBusy) {
                        model.commitLayout()
                    }
                } else {
                    if let note = model.tilingNote {
                        Text(verbatim: note)
                            .font(Theme.font(.xs))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: compact ? 260 : 200, alignment: .trailing)
                    }
                    if model.undoOffered {
                        WindowsPillButton(text: AgentsText.t("Undo"), symbol: "arrow.uturn.backward", prominent: false,
                                          enabled: !model.tilingBusy) {
                            model.undoTiling()
                        }
                        .help("⌘Z")
                    }
                    if !compact {
                        if let reason = availability.reason {
                            Text(AgentsText.t("Tiling needs Accessibility"))
                                .font(Theme.font(.xs))
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                                .help(reason)
                        }
                        WindowsPillButton(text: AgentsText.t("Lay out sessions"), symbol: "rectangle.split.2x2",
                                          prominent: false,
                                          enabled: availability == .ready && liveCount > 0 && !model.tilingBusy) {
                            model.layOutSessions()
                        }
                        .help(availability.reason ?? AgentsText.t("Preview every live session's terminal tiled on this display; click again or press ⏎ to apply."))
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AgentRow: View {
    let session: AgentSession
    let pulsing: Bool
    let note: String?
    var tiling: AgentsTilingAvailability = .unavailable
    let action: () -> Void
    @State private var hover = false

    /// done is green only while fresh (2'), like the wing dots; then it reads quietly.
    private var stale: Bool { session.state == .done && !session.isFresh(at: .now) }
    private var dotColor: Color { stale ? Theme.idle : session.state.color }
    private var stateColor: Color { session.state == .working || stale ? Theme.secondary : session.state.color }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                AgentStateDot(color: dotColor, pulsing: pulsing && session.state == .working)
                    .frame(width: 16, alignment: .leading)
                Text(session.label)
                    .font(Theme.font(.m, .semibold))
                    .foregroundStyle(session.isLive && session.state != .idle ? Theme.primary : Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: 118, alignment: .leading)
                Text(AgentsText.state(session.state))
                    .font(Theme.font(.s, .medium))
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
                    .frame(width: 62, alignment: .leading)
                AgentElapsed(session: session)
                    .frame(width: 50, alignment: .trailing)
                    .padding(.trailing, 12)
                Text(toolText)
                    .font(Theme.font(.s).monospaced())
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: 92, alignment: .leading)
                    .padding(.trailing, 8)
                Text(session.lastPrompt ?? "")
                    .font(Theme.font(.s))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Theme.card : .clear))
            .contentShape(Rectangle())
            .opacity(session.state == .ended ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tooltip)
    }

    private var toolText: String {
        if session.state == .waiting, let t = session.waitingTool { return t }
        guard let tool = session.lastTool else { return "" }
        return session.lastToolAgent == nil ? tool : "↳ \(tool)"   // ↳ = a subagent's call
    }

    private var tooltip: String {
        var lines = [session.projectPath]
        if let tool = session.lastTool, let agent = session.lastToolAgent { lines.append("\(tool) · \(agent)") }
        if session.state == .waiting, let t = session.waitingTool {
            lines.append("\(AgentsText.t("needs permission for")) \(t)")
        }
        if let d = session.lastTurnDuration, session.state == .done || session.state == .failed {
            lines.append("\(AgentsText.t("last turn")) \(AgentsText.duration(d)) · \(session.turnTools) \(AgentsText.t("tools"))")
        }
        if session.state == .done, let bg = session.backgroundActivityAt, Date.now.timeIntervalSince(bg) < 120 {
            lines.append(AgentsText.t("background agents running"))
        }
        if let p = session.lastPrompt { lines.append("“\(p)”") }
        if let note {
            lines.append(note)
        } else if !TerminalJumper.isTrusted {
            lines.append(AgentsText.t("Accessibility is off: Glancy can bring the terminal app forward, not the exact window."))
        } else {
            lines.append(AgentsText.t("Click to bring its terminal forward."))
        }
        switch tiling {
        case .ready: lines.append(AgentsText.t("⌥-click to also tile it into the focused cell."))
        case .needsAccessibility: lines.append(AgentsText.t("⌥-click to tile needs Accessibility."))
        case .unavailable: break
        }
        return lines.joined(separator: "\n")
    }
}

/// Live timer while working/waiting (SwiftUI updates it itself, only while on screen);
/// a compact age otherwise.
struct AgentElapsed: View {
    let session: AgentSession

    var body: some View {
        Group {
            switch session.state {
            case .working:
                Text(timerInterval: (session.turnStartedAt ?? session.stateSince)...Date.distantFuture, countsDown: false)
            case .waiting:
                Text(timerInterval: session.stateSince...Date.distantFuture, countsDown: false)
            default:
                Text(AgentsText.age(Date.now.timeIntervalSince(session.stateSince)))
            }
        }
        .font(Theme.font(.s).monospacedDigit())
        .foregroundStyle(session.state == .waiting ? Theme.waiting : Theme.secondary)
        .lineLimit(1)
    }
}

private struct AgentsEmptyState: View {
    let loaded: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(Theme.font(.xl))
                .foregroundStyle(Theme.tertiary)
            Text(AgentsText.t("No Claude Code sessions"))
                .font(Theme.font(.l, .medium))
                .foregroundStyle(Theme.secondary)
            Text(AgentsText.t("Sessions appear here as soon as Claude Code runs."))
                .font(Theme.font(.s))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(loaded ? 1 : 0)
    }
}

// MARK: Home card

/// The Home card's overflow: "Lay out sessions" (disabled with its reason without Accessibility).
private struct AgentsHomeOverflow: View {
    let model: AgentsModel

    var body: some View {
        let availability = model.tilingAvailability
        if availability != .unavailable {
            Menu {
                Button(AgentsText.t("Lay out sessions")) { model.layOutSessions() }
                    .disabled(availability != .ready || model.dots.isEmpty || model.tilingBusy)
                if let reason = availability.reason {
                    Text(reason)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 18, height: 14)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(AgentsText.t("More"))
        }
    }
}

struct AgentsHomeCard: View {
    let model: AgentsModel

    var body: some View {
        let top = model.highlights(limit: 2)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(AgentsText.t("Agents"))
                    .font(Theme.font(.xs, .semibold))
                    .foregroundStyle(Theme.tertiary)
                Spacer(minLength: 6)
                // The tiling state takes the dots' place: the card keeps its height.
                if model.layoutPreview != nil || model.undoOffered || model.tilingNote != nil {
                    AgentsTilingControls(model: model, liveCount: model.dots.count, compact: true)
                } else {
                    AgentsWingLeft(model: model)
                }
                AgentsHomeOverflow(model: model)
            }
            .frame(height: 16)
            ForEach(top, id: \.rowID) { s in
                Button { model.jump(to: s.rowID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            AgentStateDot(color: s.state.color, pulsing: model.pulse && s.state == .working)
                            Text(s.label)
                                .font(Theme.font(.l, .semibold))
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1).truncationMode(.middle)
                            Text(AgentsText.state(s.state))
                                .font(Theme.font(.s, .medium))
                                .foregroundStyle(s.state == .working ? Theme.secondary : s.state.color)
                            Spacer(minLength: 4)
                            AgentElapsed(session: s)
                        }
                        if let p = s.lastPrompt, s.rowID == top.first?.rowID {
                            Text(p)
                                .font(Theme.font(.s))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1).truncationMode(.tail)
                                .padding(.leading, 12)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
