import AppKit
import SwiftUI

/// The timer's accent: warm for focus and plain timers, green for breaks.
enum TimerTint {
    static let focus = Color(red: 0.98, green: 0.55, blue: 0.42)
    static func color(isBreak: Bool) -> Color { isBreak ? Theme.done : focus }
    static func color(_ s: TimerState) -> Color { color(isBreak: s.isBreakRun) }
}

/// A progress ring. Static: it draws the value it is given and never animates on its own.
struct TimerRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle().trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(progress > 0 ? 1 : 0)
        }
        .padding(lineWidth / 2)
    }
}

private struct Caption: View {
    let text: String
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
    }
}

/// The countdown: SwiftUI's own self-updating text while running, a static string while paused.
private struct Countdown: View {
    let state: TimerState
    let now: Date
    var body: some View {
        if state.status == .running, let deadline = state.deadline, deadline > now {
            Text(timerInterval: now...deadline, countsDown: true)
        } else {
            Text(verbatim: TimerFormat.clock(TimerMachine.remaining(state, now: now)))
        }
    }
}

// MARK: - Wings and peek

/// What the collapsed wing shows: values frozen at publish time, so nothing ticks while collapsed
/// (except the seconds count of the last ten seconds).
struct TimerWingSnapshot {
    var progress: Double
    var minutesLeft: Int
    var paused: Bool
    var isBreak: Bool
    var finishingUntil: Date?
    /// "Focus" / "Break" before the minutes (Pomodoro and break timers).
    var label: TimerText.WingKind? = nil
    /// A Pomodoro phase waiting for Start.
    var held = false
}

struct TimerWingLeft: View {
    let snap: TimerWingSnapshot
    var body: some View {
        ZStack {
            TimerRing(progress: snap.progress, color: snap.paused && !snap.held ? Theme.tertiary : TimerTint.color(isBreak: snap.isBreak), lineWidth: 2.5)
                .frame(width: 15, height: 15)
            if snap.paused, !snap.held {
                Image(systemName: "pause.fill").font(.system(size: 6, weight: .bold)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.leading, 6)
    }
}

struct TimerWingRight: View {
    let snap: TimerWingSnapshot
    var body: some View {
        Group {
            if let until = snap.finishingUntil, until > .now {
                Text(timerInterval: Date.now...until, countsDown: true)
                    .font(Theme.font(.s, .semibold)).foregroundStyle(TimerTint.color(isBreak: snap.isBreak))
            } else {
                Text(verbatim: TimerText.wing(snap.label, minutes: snap.minutesLeft, held: snap.held))
                    .font(Theme.font(.s, .medium))
                    .foregroundStyle(snap.held ? TimerTint.color(isBreak: snap.isBreak) : snap.paused ? Theme.tertiary : Theme.primary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.trailing, 6)
        .frame(maxWidth: Theme.wingMaxWidth, alignment: .trailing)
    }
}

struct TimerPeek: View {
    let event: TimerEvent
    var body: some View {
        let (title, detail) = TimerText.peek(event)
        let isBreakNext: Bool = if case .phaseChanged(_, let to) = event { !Pomodoro.isFocus(to) } else { false }
        HStack(spacing: 8) {
            TimerRing(progress: 1, color: TimerTint.color(isBreak: isBreakNext), lineWidth: 2.5).frame(width: 16, height: 16)
            Text(verbatim: title).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
            Text(verbatim: detail).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
        }
        .lineLimit(1)
    }
}

// MARK: - Home card

struct TimerHomeCard: View {
    let timer: TimerModule
    let model: TimerModel
    var body: some View {
        let s = model.state
        HStack(spacing: 10) {
            TimerRing(progress: model.progress, color: s.status == .paused ? Theme.tertiary : TimerTint.color(s), lineWidth: 3)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Caption(text: s.status == .paused && !s.isHeld ? TimerText.caption(s) + " · " + L10n.tr("Paused") : TimerText.caption(s))
                Countdown(state: s, now: model.now)
                    .font(.system(size: 20, weight: .light)).monospacedDigit()
                    .foregroundStyle(s.status == .paused ? Theme.secondary : Theme.primary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if s.status == .running {
                    RoundIcon(symbol: "pause.fill", help: L10n.tr("Pause")) { timer.pause() }
                } else {
                    RoundIcon(symbol: "play.fill", help: L10n.tr("Resume")) { timer.resume() }
                }
                RoundIcon(symbol: "stop.fill", help: L10n.tr("Stop")) { timer.stopTimer() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RoundIcon: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct PillButton: View {
    let title: String
    var filled = false
    var width: CGFloat?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(Theme.font(.m, .medium)).monospacedDigit()
                .foregroundStyle(filled ? Color.black : hover ? Theme.primary : Theme.secondary)
                .padding(.horizontal, width == nil ? 12 : 0)
                .frame(width: width, height: 26)
                .background(Capsule().fill(filled ? Theme.primary : Color.white.opacity(hover ? 0.12 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Tab

struct TimerTabView: View {
    let timer: TimerModule
    let model: TimerModel

    var body: some View {
        let s = model.state
        HStack(spacing: 22) {
            ZStack {
                TimerRing(progress: s.isActive ? model.progress : 0,
                          color: s.status == .paused ? Theme.secondary : TimerTint.color(s), lineWidth: 5)
                    .animation(.linear(duration: 1), value: model.progress)
                VStack(spacing: 2) {
                    if s.isActive {
                        Countdown(state: s, now: model.now)
                            .font(.system(size: 24, weight: .light)).monospacedDigit()
                            .foregroundStyle(s.status == .paused ? Theme.secondary : Theme.primary)
                        if s.status == .paused, !s.isHeld {
                            Text(verbatim: L10n.tr("Paused")).font(Theme.font(.xs, .medium)).foregroundStyle(Theme.tertiary)
                        }
                    } else {
                        Text(verbatim: TimerFormat.clock(TimeInterval(model.customMinutes * 60)))
                            .font(.system(size: 24, weight: .light)).monospacedDigit()
                            .foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .frame(width: 112, height: 112)
            .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 10) {
                if s.isActive { running(s) } else { idle }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private func running(_ s: TimerState) -> some View {
        HStack(spacing: 8) {
            Caption(text: TimerText.caption(s))
            if s.phase != nil { RoundDots(phase: s.phase ?? 0, held: s.isHeld) }
        }
        HStack(spacing: 8) {
            if s.isHeld {
                PillButton(title: TimerText.startHeld(s), filled: true) { timer.resume() }
            } else if s.status == .running {
                RoundIcon(symbol: "pause.fill", help: L10n.tr("Pause"), size: 34) { timer.pause() }
            } else {
                RoundIcon(symbol: "play.fill", help: L10n.tr("Resume"), size: 34) { timer.resume() }
            }
            RoundIcon(symbol: "stop.fill", help: L10n.tr("Stop"), size: 34) { timer.stopTimer() }
            if !s.isHeld { PillButton(title: L10n.tr("+1 min")) { timer.addMinute() } }
            if s.phase != nil, !s.isHeld {
                RoundIcon(symbol: "forward.end.fill", help: L10n.tr("Skip to the next phase"), size: 34) { timer.skip() }
            }
        }
        if let next = TimerText.upNext(s), !s.isHeld {
            Text(verbatim: L10n.tr("Up next") + " · " + next).font(Theme.font(.s)).foregroundStyle(Theme.secondary)
        } else if let deadline = s.deadline {
            Text(verbatim: "→ " + deadline.formatted(date: .omitted, time: .shortened))
                .font(Theme.font(.s)).monospacedDigit().foregroundStyle(Theme.tertiary)
        }
        if s.phase != nil, model.roundsToday > 0 {
            Text(verbatim: TimerText.roundsToday(model.roundsToday)).font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
        }
    }

    @ViewBuilder private var idle: some View {
        Caption(text: L10n.tr("Ready when you are"))
        HStack(spacing: 6) {
            ForEach(TimerMachine.presets, id: \.self) { m in
                PillButton(title: "\(m)′", width: 44) { timer.start(minutes: m) }
            }
        }
        HStack(spacing: 6) {
            RoundIcon(symbol: "minus", help: "−", size: 26) { timer.setCustomMinutes(model.customMinutes - 1) }
            Text(verbatim: TimerText.minutes(model.customMinutes))
                .font(Theme.font(.m, .medium)).monospacedDigit().foregroundStyle(Theme.primary)
                .frame(width: 56)
                .overlay(ScrollStepper { step in timer.setCustomMinutes(model.customMinutes + step) })
                .help(L10n.tr("Scroll or use − + to set minutes"))
            RoundIcon(symbol: "plus", help: "+", size: 26) { timer.setCustomMinutes(model.customMinutes + 1) }
            PillButton(title: L10n.tr("Start"), filled: true) { timer.startCustom() }
        }
        HStack(spacing: 10) {
            Button { timer.startPomodoro() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "repeat").font(.system(size: 10, weight: .semibold))
                    Text(verbatim: L10n.tr("Pomodoro")).font(Theme.font(.s, .semibold))
                    Text(verbatim: L10n.tr("%d / %d ×4, then %d", Pomodoro.lengths.focus, Pomodoro.lengths.shortBreak, Pomodoro.lengths.longBreak)).font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                }
                .foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.roundsToday > 0 {
                Text(verbatim: "· " + TimerText.roundsToday(model.roundsToday)).font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

/// Four dots, one per focus round: done ones filled, the current one ringed.
private struct RoundDots: View {
    let phase: Int
    let held: Bool
    var body: some View {
        let current = Pomodoro.round(of: phase)
        HStack(spacing: 4) {
            ForEach(1...Pomodoro.rounds, id: \.self) { r in
                let done = r < current || (r == current && !Pomodoro.isFocus(phase))
                Circle()
                    .fill(done ? TimerTint.focus : Color.white.opacity(0.14))
                    .overlay(Circle().strokeBorder(r == current && Pomodoro.isFocus(phase) ? TimerTint.focus : .clear, lineWidth: 1.2))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// Vertical scroll over the minutes value steps it by one per notch (or per ~8 pt of trackpad
/// travel). Horizontal scrolls pass through, so the panel's two-finger tab swipe still works.
private struct ScrollStepper: NSViewRepresentable {
    let onStep: (Int) -> Void
    func makeNSView(context: Context) -> StepperView { StepperView() }
    func updateNSView(_ view: StepperView, context: Context) { view.onStep = onStep }

    final class StepperView: NSView {
        var onStep: ((Int) -> Void)?
        private var accumulated: CGFloat = 0
        override func scrollWheel(with event: NSEvent) {
            let dy = event.scrollingDeltaY, dx = event.scrollingDeltaX
            guard abs(dy) > abs(dx) else { super.scrollWheel(with: event); return }
            if !event.hasPreciseScrollingDeltas {
                onStep?(dy > 0 ? 1 : -1)
                return
            }
            accumulated += dy
            while abs(accumulated) >= 8 {
                onStep?(accumulated > 0 ? 1 : -1)
                accumulated -= accumulated > 0 ? 8 : -8
            }
            if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) { accumulated = 0 }
        }
    }
}
