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

/// A state dot. A working dot breathes (0.8 s to 40 % and 0.8 s back), only while `pulsing`.
///
/// No repeating animation: each half-breath is one finite animation whose completion starts the
/// next one while the dot still pulses. A repeating animation cannot be stopped in place: an unanimated
/// write is combined with the running repeat (SwiftUI's DefaultCombiningAnimation) and the dot kept
/// breathing, invisible or not, after `pulsing` went false: the closed notch on the other display
/// was laid out on every frame (2.8% CPU on a two-display Mac). Now the breath ends by itself at
/// most 1.6 s after `pulsing` goes false or the dot disappears.
struct AgentStateDot: View {
    let color: Color
    let pulsing: Bool
    var size: CGFloat = 6
    @State private var dim = false
    /// `pulsing` as of the last change, read by the completion of the running half-breath.
    @State private var live = false
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.4 : 1)
            .onChange(of: pulsing, initial: true) { _, on in
                live = on
                if on, !breathing { breathe() }
            }
            .onDisappear { live = false }
    }

    /// One half-breath, then the next while live; a dimmed dot always comes back to full first.
    private func breathe() {
        guard live || dim else { breathing = false; return }
        breathing = true
        withAnimation(.easeInOut(duration: 0.8), completionCriteria: .logicallyComplete) {
            dim.toggle()
        } completion: {
            breathe()
        }
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
                // Still in the wings: a closed surface never animates (one may be on screen beside an open
                // panel on another display, and nothing there would ever stop it).
                AgentStateDot(color: d.color, pulsing: false)
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
    /// The agent and app of the session it is about (one session only), shown as small badges.
    var agent: AgentKind? = nil
    var host: AgentHost? = nil

    var body: some View {
        HStack(spacing: 7) {
            AgentStateDot(color: state.color, pulsing: false, size: 7)
            if let agent {
                AgentBadges(agent: agent, host: host, size: 13)
            }
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
                        ForEach(Array(rows.enumerated()), id: \.element.rowID) { i, s in
                            if i > 0, AgentsBoard.group(rows[i - 1].state) != AgentsBoard.group(s.state) {
                                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 2)
                            }
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

extension AgentsBoard {
    /// Attention groups on the board: needs you, working, the rest (separated by a hairline).
    static func group(_ s: AgentState) -> Int {
        switch s {
        case .waiting: 0
        case .working: 1
        default: 2
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
                    .frame(width: 14, alignment: .leading)
                AgentBadges(agent: session.agent, host: session.host)
                    .frame(width: 36, alignment: .leading)
                Text(session.label)
                    .font(Theme.font(.m, .semibold))
                    .foregroundStyle(session.isLive && session.state != .idle ? Theme.primary : Theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: 108, alignment: .leading)
                Text(AgentsText.state(session.state))
                    .font(Theme.font(.s, .medium))
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .leading)
                AgentElapsed(session: session)
                    .frame(width: 46, alignment: .trailing)
                    .padding(.trailing, 10)
                Text(toolText)
                    .font(Theme.font(.s).monospaced())
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: 78, alignment: .leading)
                    .padding(.trailing, 8)
                Text(AgentRow.text(session))
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

    /// The row's last words: the reply once a turn is over (sources that record it), else the
    /// last prompt, else the title.
    static func text(_ s: AgentSession) -> String {
        if s.state != .working, s.state != .waiting, let m = s.lastMessage { return m }
        return s.lastPrompt ?? s.title ?? ""
    }

    private var toolText: String {
        if session.state == .waiting, let t = session.waitingTool { return t }
        guard let tool = session.lastTool else { return "" }
        return session.lastToolAgent == nil ? tool : "↳ \(tool)"   // ↳ = a subagent's call
    }

    private var tooltip: String {
        var lines = [session.projectPath]
        lines.append([session.agent.name, session.host.map(\.name)].compactMap { $0 }.joined(separator: " · "))
        if let t = session.title, t != session.lastPrompt { lines.append(t) }
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
        if let m = session.lastMessage { lines.append("→ \(m)") }
        let plan = AgentJump.plan(for: session)
        if let note {
            lines.append(note)
        } else if case .terminal = plan, !TerminalJumper.isTrusted {
            lines.append(AgentsText.t("Accessibility is off: Glancy can bring the terminal app forward, not the exact window."))
        } else {
            lines.append(AgentsText.clickHint(plan, host: session.host))
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
            Image(systemName: AgentsModule.symbol)
                .font(Theme.font(.xl))
                .foregroundStyle(Theme.tertiary)
            Text(AgentsText.t("No agent sessions"))
                .font(Theme.font(.l, .medium))
                .foregroundStyle(Theme.secondary)
            Text(AgentsText.t("Claude Code, Codex and OpenCode sessions appear here as soon as they run."))
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
                            AgentBadges(agent: s.agent, host: s.host)
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
                        if s.rowID == top.first?.rowID, case let p = AgentRow.text(s), !p.isEmpty {
                            Text(p)
                                .font(Theme.font(.s))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1).truncationMode(.tail)
                                .padding(.leading, 12 + 36)
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

// MARK: Source badges

/// The agent's glyph and, beside it, the app it runs in (the app's real icon when known).
struct AgentBadges: View {
    let agent: AgentKind
    let host: AgentHost?
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: agent.symbol)
                .font(.system(size: size * 0.64, weight: .bold))
                .foregroundStyle(agent.tint)
                .frame(width: size, height: size)
            if let host, host.kind != .unknown {
                if let icon = AgentAppIcons.icon(for: host) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size + 1, height: size + 1)
                } else {
                    Image(systemName: host.symbol)
                        .font(.system(size: size * 0.6, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: size, height: size)
                }
            }
        }
        .help([agent.name, host?.name].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([agent.name, host?.name].compactMap { $0 }.joined(separator: ", "))
    }
}

extension AgentKind {
    /// Each agent's glyph colour: Claude's coral, Codex white, OpenCode a quiet grey-blue.
    var tint: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Theme.primary
        case .opencode: Color(red: 0.62, green: 0.70, blue: 0.82)
        }
    }
}

/// App icons for the host badges: looked up through NSWorkspace while the panel is open, a
/// handful at most, dropped when it closes (nothing held at idle).
@MainActor
enum AgentAppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var missing = Set<String>()

    static func icon(for host: AgentHost) -> NSImage? {
        guard let b = host.bundleID ?? AgentJump.editorBundles[host.kind] else { return nil }
        if let i = cache[b] { return i }
        guard !missing.contains(b) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else {
            missing.insert(b)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        if cache.count >= 12 { cache.removeAll() }
        cache[b] = icon
        return icon
    }

    static func clear() {
        cache.removeAll()
        missing.removeAll()
    }

    static var count: Int { cache.count }
}
