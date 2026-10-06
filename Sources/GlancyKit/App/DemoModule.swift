import SwiftUI

/// Sample content for `--demo` and for the renderer: a "now playing" with wings, peeks, a Home card
/// and a tab, plus a focus timer card and tab. Uses wave-2 module ids so it never collides with the
/// real wave-1 modules; `Modules.make(demo:)` drops a demo whose id a real module already uses.
@MainActor
public final class DemoModule: GlancyModule {
    public enum Kind: Sendable { case media, timer }

    public let id: ModuleID
    private let kind: Kind
    private weak var hub: ActivityHub?
    private var loop: Task<Void, Never>?
    private var visibility: SurfaceVisibility = .collapsed
    private var started = false
    /// Off in the renderer: no periodic peeks.
    public var cyclesPeeks = true
    private let timerEnd = Date.now.addingTimeInterval(18 * 60 + 42)

    public init(kind: Kind) {
        self.kind = kind
        id = kind == .media ? .media : .timer
    }

    public static func suite() -> [DemoModule] { [DemoModule(kind: .media), DemoModule(kind: .timer)] }

    public func start(hub: ActivityHub) {
        self.hub = hub
        started = true
        guard kind == .media else { return }
        hub.post(LiveActivity(id: "demo.media", module: id, priority: 30,
                              left: AnyView(ArtworkTile(size: 20.ui, radius: 5)),
                              right: AnyView(LevelBars())))
        restartLoop()
    }

    public func stop() {
        started = false
        loop?.cancel(); loop = nil
        hub?.clearAll(from: id)
    }

    public func visibilityChanged(_ v: SurfaceVisibility) {
        visibility = v
        restartLoop()
    }

    /// The demo peeks: a track change and an AirPods connection, alternately.
    public func showSamplePeek(_ n: Int = 0) {
        guard kind == .media else { return }
        let content = n % 2 == 0 ? AnyView(TrackPeek()) : AnyView(AirPodsPeek())
        hub?.show(PeekEvent(module: id, content: content))
    }

    /// Peeks only while the surface is collapsed and on screen: never while hidden.
    private func restartLoop() {
        loop?.cancel(); loop = nil
        guard started, cyclesPeeks, kind == .media, visibility == .collapsed else { return }
        loop = Task { [weak self] in
            var n = 0
            try? await Delay.sleep(for: .seconds(3))
            while !Task.isCancelled {
                self?.showSamplePeek(n)
                n += 1
                try? await Delay.sleep(for: .seconds(30))
            }
        }
    }

    public var tab: PanelTab? {
        switch kind {
        case .media: PanelTab(module: id, symbol: "music.note", title: "Media") { AnyView(MediaTab()) }
        case .timer: PanelTab(module: id, symbol: "timer", title: "Timer") { [timerEnd] in AnyView(TimerTab(end: timerEnd)) }
        }
    }

    public func homeCard() -> AnyView? {
        switch kind {
        case .media: AnyView(MediaCard())
        case .timer: AnyView(TimerCard(end: timerEnd))
        }
    }
}

// MARK: - Demo views

private let accent = Color(red: 0.98, green: 0.55, blue: 0.42)

/// A stand-in for album art: warm shapes on dusk colours.
struct ArtworkTile: View {
    var size: CGFloat
    var radius: CGFloat
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.52, blue: 0.38), Color(red: 0.42, green: 0.20, blue: 0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1.0, green: 0.86, blue: 0.62).opacity(0.9))
                .frame(width: size * 0.42).offset(x: size * 0.12, y: -size * 0.08)
            Rectangle().fill(Color.black.opacity(0.28)).frame(height: size * 0.32).offset(y: size * 0.34)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Three static level bars (static: animating them is the Media module's job, only while visible).
struct LevelBars: View {
    var body: some View {
        HStack(alignment: .center, spacing: 2.ui) {
            ForEach([9.0, 14.0, 7.0, 11.0], id: \.self) { h in
                Capsule().fill(accent).frame(width: 2.5.ui, height: h)
            }
        }
        .frame(height: 20.ui)
    }
}

private struct TrackPeek: View {
    var body: some View {
        HStack(spacing: 8.ui) {
            ArtworkTile(size: 20.ui, radius: 5)
            Text("Nightswimming").font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
            Text("R.E.M.").font(Theme.font(.m)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct AirPodsPeek: View {
    var body: some View {
        HStack(spacing: 8.ui) {
            Image(systemName: "airpodspro").font(.system(size: 14.ui)).foregroundStyle(Theme.primary)
            Text(L10n.tr("AirPods Pro connected")).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
            HStack(spacing: 3.ui) {
                Image(systemName: "battery.75percent").font(.system(size: 12.ui))
                Text("82%").font(Theme.font(.m)).monospacedDigit()
            }
            .foregroundStyle(Theme.done)
        }
    }
}

private struct Caption: View {
    let text: String
    var body: some View {
        Text(L10n.tr(text).uppercased())
            .font(.system(size: 9.5.ui, weight: .semibold)).tracking(0.6.ui)
            .foregroundStyle(Theme.tertiary)
    }
}

private struct Progress: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(Theme.primary).frame(width: g.size.width * value)
            }
        }
        .frame(height: 3.ui)
    }
}

private struct MediaCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8.ui) {
            Caption(text: "Now playing")
            HStack(spacing: 10.ui) {
                ArtworkTile(size: 44.ui, radius: 9)
                VStack(alignment: .leading, spacing: 2.ui) {
                    Text("Nightswimming").font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Text("R.E.M. · Automatic for the People").font(Theme.font(.s)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Progress(value: 0.38)
            HStack {
                Text("1:52").font(Theme.font(.xs)).monospacedDigit()
                Spacer()
                Text("-3:06").font(Theme.font(.xs)).monospacedDigit()
            }
            .foregroundStyle(Theme.tertiary)
        }
    }
}

private struct TimerCard: View {
    let end: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6.ui) {
            Caption(text: "Focus")
            Text(timerInterval: Date.now...end, countsDown: true)
                .font(.system(size: 30.ui, weight: .light)).monospacedDigit()
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 0)
            Text(L10n.tr("Up next") + " · 5 min break").font(Theme.font(.s)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct MediaTab: View {
    var body: some View {
        HStack(spacing: 16.ui) {
            ArtworkTile(size: 118.ui, radius: 14)
            VStack(alignment: .leading, spacing: 4.ui) {
                Text("Nightswimming").font(Theme.font(.xl, .semibold)).foregroundStyle(Theme.primary)
                Text("R.E.M. · Automatic for the People").font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Progress(value: 0.38)
                HStack {
                    Text("1:52").font(Theme.font(.xs)).monospacedDigit()
                    Spacer()
                    Text("-3:06").font(Theme.font(.xs)).monospacedDigit()
                }
                .foregroundStyle(Theme.tertiary)
                HStack(spacing: 30.ui) {
                    Image(systemName: "backward.fill")
                    Image(systemName: "pause.fill").font(.system(size: 22.ui))
                    Image(systemName: "forward.fill")
                }
                .font(.system(size: 16.ui))
                .foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4.ui)
            }
            .padding(.vertical, 2.ui)
        }
    }
}

private struct TimerTab: View {
    let end: Date
    var body: some View {
        HStack(spacing: 22.ui) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 5.ui)
                Circle().trim(from: 0, to: 0.62)
                    .stroke(accent, style: StrokeStyle(lineWidth: 5.ui, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(timerInterval: Date.now...end, countsDown: true)
                    .font(.system(size: 22.ui, weight: .light)).monospacedDigit()
                    .foregroundStyle(Theme.primary)
            }
            .frame(width: 100.ui, height: 100.ui)
            .padding(.leading, 4.ui)
            VStack(alignment: .leading, spacing: 10.ui) {
                Caption(text: "Focus")
                HStack(spacing: 6.ui) {
                    ForEach(["5", "15", "25", "50"], id: \.self) { m in
                        Text("\(m)′").font(Theme.font(.m, .medium)).foregroundStyle(m == "25" ? Color.black : Theme.secondary)
                            .frame(width: 40.ui, height: 26.ui)
                            .background(Capsule().fill(m == "25" ? Theme.primary : Theme.card))
                    }
                }
                Text(L10n.tr("Sample content, shown with --demo.")).font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}
