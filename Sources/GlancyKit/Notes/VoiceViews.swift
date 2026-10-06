import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Voice notes on screen: the recording panel (meter + time), the cards (mic off, mic muted), the
// player strip (play, waveform scrub, speed, drag out), the wing and the "saved" drop-down.

// MARK: Wing (collapsed, while recording)

struct VoiceWingLeft: View {
    var body: some View {
        HStack(spacing: 5.ui) {
            Circle().fill(Theme.failed).frame(width: 7.ui, height: 7.ui)
            Image(systemName: "mic.fill").font(.system(size: 10.ui, weight: .semibold)).foregroundStyle(Theme.primary)
        }
        .padding(.horizontal, 4.ui)
    }
}

/// Elapsed time; refreshed once a second by `VoiceNotes`' tick while recording and collapsed.
struct VoiceWingRight: View {
    let voice: VoiceNotes
    var body: some View {
        Text(verbatim: VoiceTime.format(voice.elapsed))
            .font(Theme.font(.s, .semibold).monospacedDigit())
            .foregroundStyle(Theme.failed)
            .padding(.horizontal, 4.ui)
    }
}

struct VoiceSavedPeek: View {
    let duration: TimeInterval
    var body: some View {
        HStack(spacing: 7.ui) {
            Image(systemName: "waveform").font(.system(size: 12.ui, weight: .semibold)).foregroundStyle(Theme.done)
            Text(verbatim: L10n.tr("Voice note saved")).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
            Text(verbatim: VoiceTime.format(duration)).font(Theme.font(.m).monospacedDigit()).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 12.ui)
        .fixedSize()
    }
}

// MARK: Recording panel (the tab, while recording)

struct VoiceRecordingPanel: View {
    let voice: VoiceNotes
    let stop: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8.ui) {
            HStack(spacing: 6.ui) {
                Circle().fill(Theme.failed).frame(width: 7.ui, height: 7.ui)
                Text(verbatim: voice.phase == .saving ? L10n.tr("Saving…") : L10n.tr("Recording"))
                    .font(Theme.font(.s, .semibold)).foregroundStyle(Theme.primary)
                Spacer(minLength: 4.ui)
                Text(verbatim: L10n.tr("Stops at %d min", voice.settings.maxMinutes))
                    .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
            VoiceMeter(levels: voice.levels)
                .frame(height: 44.ui)
            Spacer(minLength: 0)
            HStack(spacing: 8.ui) {
                Text(verbatim: VoiceTime.format(voice.elapsed))
                    .font(.system(size: 24.ui, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 4.ui)
                NotchTextButton(L10n.tr("Discard"), action: cancel)
                Button(action: stop) {
                    HStack(spacing: 6.ui) {
                        RoundedRectangle(cornerRadius: 2.ui, style: .continuous).fill(Color.white).frame(width: 9.ui, height: 9.ui)
                        Text(verbatim: L10n.tr("Stop")).font(Theme.font(.s, .semibold)).foregroundStyle(Color.white)
                    }
                    .padding(.horizontal, 12.ui)
                    .frame(height: 26.ui)
                    .background(Capsule().fill(Theme.failed))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("Stop and save"))
                .disabled(voice.phase != .recording)
            }
        }
        .padding(12.ui)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10.ui, style: .continuous).fill(Theme.card))
    }
}

/// The last input levels as bars around a centre line, newest on the right.
struct VoiceMeter: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { geo in
            let count = VoiceNotes.meterBars
            let padded = Array(repeating: Float(0), count: max(0, count - levels.count)) + levels.suffix(count)
            let gap: CGFloat = 3.ui
            let w = max(1, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(padded.indices, id: \.self) { i in
                    Capsule()
                        .fill(i >= count - levels.count ? Theme.failed.opacity(0.9) : Theme.hairline)
                        .frame(width: w, height: max(3.ui, CGFloat(padded[i]) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: Cards

struct VoiceCardView: View {
    let card: VoiceNotes.Card
    let voice: VoiceNotes

    var body: some View {
        HStack(alignment: .top, spacing: 12.ui) {
            Image(systemName: symbol)
                .font(.system(size: 20.ui, weight: .medium))
                .foregroundStyle(card == .micMuted ? Theme.waiting : Theme.secondary)
                .frame(width: 28.ui)
            VStack(alignment: .leading, spacing: 5.ui) {
                Text(verbatim: title).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                Text(verbatim: message).font(Theme.font(.s)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6.ui) {
                    switch card {
                    case .micDenied:
                        NotchTextButton(L10n.tr("Open Settings")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    case .micMuted:
                        NotchTextButton(L10n.tr("Unmute and record")) { Task { await voice.unmuteAndRecord() } }
                    case .failed:
                        EmptyView()
                    }
                    NotchTextButton(card == .failed ? L10n.tr("OK") : L10n.tr("Not now")) { voice.card = nil }
                }
                .padding(.top, 3.ui)
            }
            Spacer(minLength: 0)
        }
        .padding(14.ui)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10.ui, style: .continuous).fill(Theme.card))
    }

    private var symbol: String {
        switch card {
        case .micDenied: "mic.slash"
        case .micMuted: "mic.slash.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch card {
        case .micDenied: L10n.tr("Microphone access is off")
        case .micMuted: L10n.tr("Mic muted — unmute to record")
        case .failed: L10n.tr("Couldn't record")
        }
    }

    private var message: String {
        switch card {
        case .micDenied: L10n.tr("Glancy needs the microphone to record voice notes. Turn it on in System Settings → Privacy & Security → Microphone.")
        case .micMuted: L10n.tr("Your microphone is muted, so a recording would be silent.")
        case .failed: L10n.tr("No microphone could be opened. Check the input in System Settings → Sound.")
        }
    }
}

/// "Transcribe on this Mac?" — shown once, before Speech Recognition is asked for.
struct VoiceSpeechAsk: View {
    let voice: VoiceNotes
    let noteID: String

    var body: some View {
        HStack(spacing: 8.ui) {
            Image(systemName: "text.bubble").font(.system(size: 12.ui, weight: .medium)).foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: L10n.tr("Turn voice notes into text?")).font(Theme.font(.s, .semibold)).foregroundStyle(Theme.primary)
                Text(verbatim: L10n.tr("On this Mac only: the audio never leaves it."))
                    .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4.ui)
            NotchTextButton(L10n.tr("Not now")) { voice.declineTranscription() }
            NotchTextButton(L10n.tr("Transcribe")) { Task { await voice.transcribe(noteID, ask: true) } }
        }
        .padding(.horizontal, 8.ui)
        .padding(.vertical, 5.ui)
        .background(RoundedRectangle(cornerRadius: 8.ui, style: .continuous).fill(Theme.card))
    }
}

// MARK: Player

/// Play / pause, the waveform (click or drag to scrub), time, speed, and the file to drag out.
struct VoicePlayerStrip: View {
    let voice: VoiceNotes
    let note: Note
    let audio: NoteAudio
    let url: URL

    var body: some View {
        let playing = voice.playingID == note.id && voice.isPlaying
        let position = voice.position(of: note)
        let duration = max(audio.duration, 0.1)
        HStack(spacing: 8.ui) {
            Button { voice.togglePlay(note) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 11.ui, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 24.ui, height: 24.ui)
                    .background(Circle().fill(Theme.primary))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(playing ? L10n.tr("Pause") : L10n.tr("Play"))
            .disabled(voice.isRecording)
            VoiceWaveform(bars: audio.waveform, progress: min(1, position / duration)) { voice.seek(note, to: $0) }
                .frame(height: 24.ui)
            Text(verbatim: "\(VoiceTime.format(position)) / \(VoiceTime.format(audio.duration))")
                .font(Theme.font(.xs).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .fixedSize()
            Button { voice.cycleRate() } label: {
                Text(verbatim: Self.rateLabel(voice.rate))
                    .font(Theme.font(.xs, .semibold).monospacedDigit())
                    .foregroundStyle(voice.rate == 1 ? Theme.secondary : Theme.primary)
                    .frame(width: 34.ui, height: 20.ui)
                    .background(Capsule().fill(voice.rate == 1 ? Theme.card : Color.white.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("Playback speed"))
            VoiceFileChip(url: url)
        }
        .padding(.horizontal, 6.ui)
        .padding(.vertical, 4.ui)
        .background(RoundedRectangle(cornerRadius: 10.ui, style: .continuous).fill(Theme.card))
    }

    static func rateLabel(_ r: Float) -> String {
        r == 1 ? "1×" : r == 2 ? "2×" : String(format: "%.1f×", r)
    }
}

/// The recording as a file: drag it to Finder, Mail or Messages.
struct VoiceFileChip: View {
    let url: URL
    @State private var hover = false

    var body: some View {
        HStack(spacing: 3.ui) {
            Image(systemName: "doc.fill").font(.system(size: 9.ui, weight: .semibold))
            Text(verbatim: "M4A").font(.system(size: 9.ui, weight: .bold))
        }
        .foregroundStyle(hover ? Theme.primary : Theme.secondary)
        .padding(.horizontal, 6.ui)
        .frame(height: 20.ui)
        .background(Capsule().strokeBorder(Theme.hairline, lineWidth: 1.ui))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .help(L10n.tr("Drag the recording to Finder, Mail or Messages"))
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

/// Bars of a stored waveform; the played part bright. Click or drag to move the play head.
struct VoiceWaveform: View {
    let bars: [UInt8]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let shown = bars.isEmpty ? Array(repeating: UInt8(40), count: 48) : bars
            let gap: CGFloat = 2.ui
            let w = max(1, (geo.size.width - gap * CGFloat(shown.count - 1)) / CGFloat(shown.count))
            HStack(alignment: .center, spacing: gap) {
                ForEach(shown.indices, id: \.self) { i in
                    let played = (Double(i) + 0.5) / Double(shown.count) <= progress
                    Capsule()
                        .fill(played ? Theme.primary : Theme.tertiary)
                        .frame(width: w, height: max(2.ui, CGFloat(shown[i]) / 255 * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                seek(Double(max(0, min(1, v.location.x / max(1, geo.size.width)))))
            })
        }
        .accessibilityLabel(L10n.tr("Recording"))
    }
}
