import AppKit
import SwiftUI

// MARK: Pieces

/// The artwork, or a quiet placeholder while it loads / when there is none.
struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.card
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.38, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Three level bars. Static unless `phase` moves (only the expanded views pass one).
struct LevelGlyph: View {
    let playing: Bool
    let tint: Color
    var phase: Int? = nil
    var scale: CGFloat = 1

    private static let still: [CGFloat] = [0.6, 1.0, 0.75]

    private func height(_ i: Int) -> CGFloat {
        guard let phase, phase != 0 else { return Self.still[i] }
        // A cheap deterministic wobble: different per bar, per tick.
        let x = sin(Double(phase &* (i + 2)) * 1.7 + Double(i) * 2.1)
        return CGFloat(0.35 + 0.65 * abs(x))
    }

    var body: some View {
        let h = 12 * scale
        if playing { bars(h) } else {
            // Paused reads as paused, not as an ellipsis of flat bars.
            Image(systemName: "pause.fill")
                .font(.system(size: 9.ui * scale, weight: .bold))
                .foregroundStyle(tint.opacity(0.7))
                .frame(height: h)
        }
    }

    private func bars(_ h: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 2.ui * scale) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5.ui * scale, height: max(2.5.ui * scale, h * height(i)))
            }
        }
        .frame(height: h)
        .animation(phase == nil ? nil : .easeInOut(duration: 0.45), value: phase)
    }
}

/// The level glyph that moves with the visible-only tick (its own view: only it re-renders).
struct LiveLevelGlyph: View {
    let model: MediaModel
    var body: some View {
        LevelGlyph(playing: model.playing, tint: model.tint, phase: model.playing ? model.level : nil)
    }
}

/// Plain round control with a hover wash.
struct MediaButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 13.ui
    var box: CGFloat = 28.ui
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hover ? Theme.primary : Theme.primary.opacity(0.82))
                .frame(width: box, height: box)
                .background(Circle().fill(hover ? Theme.card : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct MediaControls: View {
    let model: MediaModel
    var large = false
    var body: some View {
        HStack(spacing: large ? 14.ui : 6.ui) {
            MediaButton(symbol: "backward.fill", label: L10n.tr("Previous"), size: large ? 14.ui : 11.ui, box: large ? 30.ui : 26.ui) { model.previous() }
            MediaButton(symbol: model.playing ? "pause.fill" : "play.fill",
                        label: L10n.tr(model.playing ? "Pause" : "Play"),
                        size: large ? 22.ui : 16.ui, box: large ? 38.ui : 30.ui) { model.toggle() }
                .contentTransition(.symbolEffect(.replace))
            MediaButton(symbol: "forward.fill", label: L10n.tr("Next"), size: large ? 14.ui : 11.ui, box: large ? 30.ui : 26.ui) { model.next() }
        }
    }
}

/// Progress line and times. Reads `model.now`, which only ticks while this is on screen.
struct MediaProgress: View {
    let model: MediaModel
    var interactive = false
    @State private var drag: Double?
    @State private var hover = false

    var body: some View {
        if let info = model.info, let duration = info.duration {
            let live = info.fraction(at: model.now) ?? 0
            let shown = drag ?? live
            VStack(spacing: 4.ui) {
                GeometryReader { g in
                    let thick: CGFloat = interactive && (hover || drag != nil) ? 5 : 3
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule().fill(Theme.primary).frame(width: max(thick, g.size.width * shown))
                    }
                    .frame(height: thick)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(interactive ? DragGesture(minimumDistance: 0)
                        .onChanged { v in drag = min(1, max(0, v.location.x / max(1, g.size.width))) }
                        .onEnded { _ in
                            if let d = drag { model.seek(to: d * duration) }
                            drag = nil
                        } : nil)
                    .animation(drag == nil ? .linear(duration: 0.5) : nil, value: shown)
                    .animation(.easeOut(duration: 0.15), value: thick)
                }
                .frame(height: interactive ? 12.ui : 3.ui)
                .onHover { hover = $0 }
                HStack {
                    Text(verbatim: NowPlayingInfo.clock(shown * duration))
                    Spacer()
                    Text(verbatim: "-" + NowPlayingInfo.clock(max(0, duration - shown * duration)))
                }
                .font(Theme.font(.xs)).monospacedDigit()
                .foregroundStyle(Theme.tertiary)
            }
        } else if model.info != nil {
            HStack(spacing: 5.ui) {
                Circle().fill(Theme.failed).frame(width: 5.ui, height: 5.ui)
                Text(verbatim: L10n.tr("Live")).font(Theme.font(.xs, .medium)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

private func subtitle(_ info: NowPlayingInfo, album: Bool) -> String {
    [info.artist, album ? info.album : nil].compactMap { $0 }.joined(separator: " · ")
}

// MARK: Wings / peek

struct MediaWingLeft: View {
    let artwork: NSImage?
    let tint: Color
    var body: some View {
        ArtworkView(image: artwork, size: 18.ui, radius: 4)
            .padding(.leading, 6.ui)
            .frame(maxWidth: Theme.wingMaxWidth, alignment: .leading)
    }
}

struct MediaWingRight: View {
    let playing: Bool
    let tint: Color
    var body: some View {
        LevelGlyph(playing: playing, tint: tint)
            .padding(.trailing, 8.ui)
            .frame(maxWidth: Theme.wingMaxWidth, alignment: .trailing)
    }
}

struct MediaPeek: View {
    let model: MediaModel
    var body: some View {
        if let info = model.info {
            HStack(spacing: 8.ui) {
                ArtworkView(image: model.artwork, size: 20.ui, radius: 4)
                Text(verbatim: info.title).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                    .lineLimit(1).frame(maxWidth: 220.ui, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                if let artist = info.artist {
                    Text(verbatim: artist).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).frame(maxWidth: 160.ui, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 12.ui)
        }
    }
}

// MARK: Home tile

struct MediaHomeTile: View {
    let model: MediaModel
    var body: some View {
        if let info = model.info {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10.ui) {
                    ArtworkView(image: model.artwork, size: 44.ui, radius: 8)
                    VStack(alignment: .leading, spacing: 2.ui) {
                        Text(verbatim: info.title).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                        Text(verbatim: subtitle(info, album: false)).font(Theme.font(.s)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 8.ui)
                MediaProgress(model: model)
                Spacer(minLength: 4.ui)
                MediaControls(model: model).frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: Tab

struct MediaTabView: View {
    let model: MediaModel
    var body: some View {
        let settings = model.lyricsSettings
        if let info = model.info {
            if settings.tabEnabled, settings.shown, model.lyrics.hasWords {
                LyricsNowPlayingPage(model: model, info: info, lyrics: model.lyrics, settings: settings)
            } else {
                NowPlayingPage(model: model, info: info)
            }
        } else {
            MediaEmpty(model: model)
        }
    }
}

private struct NowPlayingPage: View {
    let model: MediaModel
    let info: NowPlayingInfo

    var body: some View {
        HStack(alignment: .top, spacing: 16.ui) {
            Button { model.openApp() } label: {
                ArtworkView(image: model.artwork, size: 148.ui, radius: 12)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .help(model.appName.map { L10n.tr("Open %@", $0) } ?? "")

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8.ui) {
                    Text(verbatim: info.title).font(Theme.font(.xl, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Spacer(minLength: 4.ui)
                    LiveLevelGlyph(model: model)
                    if model.lyricsSettings.tabEnabled {
                        LyricsToggle(settings: model.lyricsSettings, available: model.lyrics.hasWords)
                            .padding(-4.ui)
                            .offset(y: 2.ui)
                    }
                }
                Text(verbatim: subtitle(info, album: true)).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).padding(.top, 2.ui)
                Spacer(minLength: 6.ui)
                MediaProgress(model: model, interactive: true)
                Spacer(minLength: 4.ui)
                ZStack {
                    HStack(spacing: 0) {
                        SourceChip(model: model)
                        Spacer(minLength: 0)
                        OutputChip(name: model.outputName)
                    }
                    MediaControls(model: model, large: true)
                }
                .frame(height: 38.ui)
            }
            .frame(height: 148.ui)
        }
        .padding(.top, 2.ui)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SourceChip: View {
    let model: MediaModel
    var body: some View {
        HStack(spacing: 5.ui) {
            if let icon = model.appIcon {
                Image(nsImage: icon).resizable().frame(width: 14.ui, height: 14.ui)
            }
            if let name = model.appName {
                Text(verbatim: name).font(Theme.font(.xs)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: 96.ui, alignment: .leading)
    }
}

private struct OutputChip: View {
    let name: String?
    var body: some View {
        if let name {
            HStack(spacing: 4.ui) {
                Image(systemName: icon(for: name)).font(.system(size: 10.ui, weight: .medium))
                Text(verbatim: name).font(Theme.font(.xs)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: 104.ui, alignment: .trailing)
        }
    }

    private func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("headphone") || n.contains("cuffie") || n.contains("beats") { return "headphones" }
        if n.contains("homepod") { return "homepod.fill" }
        if n.contains("tv") || n.contains("airplay") { return "airplayaudio" }
        if n.contains("display") || n.contains("monitor") { return "display" }
        return "speaker.wave.2.fill"
    }
}

private struct MediaEmpty: View {
    let model: MediaModel
    var body: some View {
        VStack(spacing: 8.ui) {
            Image(systemName: "music.note").font(.system(size: 22.ui, weight: .light)).foregroundStyle(Theme.tertiary)
            Text(verbatim: L10n.tr("Nothing playing")).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.secondary)
            Text(verbatim: L10n.tr(model.source == .scripts
                                   ? "Only Music and Spotify for now: the now-playing reader isn't working on this Mac."
                                   : "Play something in Music, Spotify or a browser and it shows up here."))
                .font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 300.ui)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 6.ui)
    }
}
