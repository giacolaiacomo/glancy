import SwiftUI

/// The Media tab with lyrics: a narrow now-playing column on the left, the words on the right
/// with the current line lit and kept in the middle.
struct LyricsNowPlayingPage: View {
    let model: MediaModel
    let info: NowPlayingInfo
    let lyrics: LyricsModel
    let settings: LyricsSettings

    var body: some View {
        HStack(alignment: .top, spacing: 14.ui) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 8.ui) {
                    Button { model.openApp() } label: { ArtworkView(image: model.artwork, size: 46.ui, radius: 8) }
                        .buttonStyle(.plain)
                        .help(model.appName.map { L10n.tr("Open %@", $0) } ?? "")
                    VStack(alignment: .leading, spacing: 1.ui) {
                        Text(verbatim: info.title).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(2)
                        if let artist = info.artist {
                            Text(verbatim: artist).font(Theme.font(.s)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 6.ui)
                MediaProgress(model: model, interactive: true)
                Spacer(minLength: 2.ui)
                MediaControls(model: model).frame(maxWidth: .infinity)
            }
            .frame(width: 168.ui)
            .frame(maxHeight: .infinity)

            ZStack(alignment: .topTrailing) {
                LyricsBody(lyrics: lyrics, tint: model.tint)
                LyricsToggle(settings: settings, available: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12.ui, style: .continuous).fill(Theme.card))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The words: timed lines scrolling with playback, or plain text to scroll by hand.
struct LyricsBody: View {
    let lyrics: LyricsModel
    let tint: Color

    var body: some View {
        switch lyrics.state {
        case .ready(.synced(let lines)):
            SyncedLines(lines: lines, lyrics: lyrics)
        case .ready(.plain(let text)):
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6.ui) {
                    Text(verbatim: L10n.tr("Not synced")).font(Theme.font(.xs, .medium)).foregroundStyle(Theme.tertiary)
                    Text(verbatim: text).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                        .lineSpacing(3.ui)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14.ui).padding(.vertical, 10.ui).padding(.trailing, 18.ui)
            }
        default:
            LyricsMessage(state: lyrics.state)
        }
    }
}

private struct SyncedLines: View {
    let lines: [LyricLine]
    let lyrics: LyricsModel

    var body: some View {
        let current = lyrics.index
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7.ui) {
                    // Room above the first line so it can sit in the middle too.
                    Color.clear.frame(height: 44.ui)
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let on = i == current
                        Text(verbatim: line.text.isEmpty ? "♪" : line.text)
                            .font(Theme.font(on ? .xl : .l, on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.primary : distance(i, current) == 1 ? Theme.secondary : Theme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                    Color.clear.frame(height: 56.ui)
                }
                .padding(.horizontal, 14.ui)
                .padding(.trailing, 18.ui)
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onAppear { proxy.scrollTo(current ?? 0, anchor: UnitPoint(x: 0, y: 0.42)) }
            .onChange(of: current) { _, new in
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(new ?? 0, anchor: UnitPoint(x: 0, y: 0.42)) }
            }
        }
    }

    private func distance(_ i: Int, _ c: Int?) -> Int { abs(i - (c ?? -1)) }
}

private struct LyricsMessage: View {
    let state: LyricsModel.State
    var body: some View {
        VStack(spacing: 6.ui) {
            Image(systemName: symbol).font(.system(size: 18.ui, weight: .light)).foregroundStyle(Theme.tertiary)
            Text(verbatim: text).font(Theme.font(.s)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 260.ui)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch state {
        case .offline: "wifi.slash"
        case .ready(.instrumental): "music.quarternote.3"
        default: "quote.bubble"
        }
    }

    private var text: String {
        switch state {
        case .loading: L10n.tr("Looking for lyrics…")
        case .offline: L10n.tr("Lyrics need a connection. Trying again next time.")
        case .ready(.instrumental): L10n.tr("Instrumental")
        case .ready(.notFound): L10n.tr("No lyrics for this track")
        default: L10n.tr("Lyrics are off")
        }
    }
}

/// Switches the Media tab between artwork and lyrics.
struct LyricsToggle: View {
    let settings: LyricsSettings
    let available: Bool
    @State private var hover = false

    var body: some View {
        let on = settings.shown && available
        Button { settings.shown.toggle() } label: {
            Image(systemName: on ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 11.ui, weight: .semibold))
                .foregroundStyle(available ? (hover || on ? Theme.primary : Theme.secondary) : Theme.tertiary.opacity(0.6))
                .frame(width: 24.ui, height: 22.ui)
                .background(Capsule().fill(hover && available ? Theme.card : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .onHover { hover = $0 }
        .help(L10n.tr(available ? (on ? "Hide lyrics" : "Show lyrics") : "No lyrics for this track"))
        .accessibilityLabel(L10n.tr(on ? "Hide lyrics" : "Show lyrics"))
        .padding(4.ui)
    }
}

/// The opt-in wing: the line being sung, in a fixed width so a new line never reshapes the notch.
struct MediaWingLyrics: View {
    let lyrics: LyricsModel
    let tint: Color
    static var width: CGFloat { Theme.wingMaxWidth - 12.ui }

    var body: some View {
        Text(verbatim: lyrics.currentText)
            .font(.system(size: 10.ui, weight: .medium))
            .foregroundStyle(Theme.primary)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(.leading)
            .frame(width: Self.width, alignment: .leading)
            .padding(.trailing, 4.ui)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: lyrics.index)
    }
}
