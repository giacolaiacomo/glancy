import SwiftUI

// Microphone wings (muted, in use, toggle flash) and the sound controls of the Devices tab.
// Theme only.

/// The recording dot: red, as a "live" light.
struct RecordingDot: View {
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(Theme.failed).frame(width: size, height: size)
    }
}

struct MicWingLeft: View {
    let muted: Bool
    var body: some View {
        Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(muted ? Theme.failed : Theme.primary)
            .frame(width: 20, alignment: .center)
            .fixedSize()
    }
}

/// "Mic muted", with the red dot when an app is recording anyway (on a call, muted).
struct MicWingRight: View {
    let audio: AudioCenter
    let showInUse: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: L10n.tr("Mic muted"))
                .font(Theme.font(.s, .medium))
                .foregroundStyle(Theme.secondary)
            if showInUse, audio.micUse.inUse || audio.cameraInUse { RecordingDot() }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The 1.5 s confirmation after a toggle; nil = nothing to mute.
struct MicFlashRight: View {
    let muted: Bool?
    var body: some View {
        Text(verbatim: muted.map { $0 ? L10n.tr("Mic muted") : L10n.tr("Mic on") } ?? L10n.tr("No microphone"))
            .font(Theme.font(.s, .medium))
            .foregroundStyle(muted == true ? Theme.secondary : Theme.primary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// What is recording: the mic, the camera or both.
struct InUseWingLeft: View {
    let audio: AudioCenter
    var body: some View {
        HStack(spacing: 4) {
            if audio.cameraInUse { Image(systemName: "video.fill") }
            if audio.micUse.inUse || !audio.cameraInUse { Image(systemName: "mic.fill") }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.primary)
        .frame(minWidth: 20, alignment: .center)
        .fixedSize()
    }
}

struct InUseWingRight: View {
    var body: some View {
        RecordingDot(size: 8)
            .frame(width: 20, alignment: .center)
            .fixedSize()
    }
}

// MARK: Devices tab: microphone + output

/// The right column of the Devices tab: the microphone (mute, in use) and the output list.
struct SoundControls: View {
    let module: HUDModule

    var body: some View {
        let audio = module.audio
        VStack(alignment: .leading, spacing: 8) {
            MicRow(audio: audio, hotkey: module.settings.micHotkey, toggle: { module.toggleMic() })
            OutputList(audio: audio)
        }
    }
}

private struct MicRow: View {
    let audio: AudioCenter
    let hotkey: Hotkey
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        let muted = audio.micMuted
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(muted ? Color.white : Theme.primary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(muted ? Theme.failed.opacity(0.85) : Color.white.opacity(hover ? 0.18 : 0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!audio.micMutable)
            .onHover { hover = $0 }
            .help(muted ? L10n.tr("Unmute") : L10n.tr("Mute"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: audio.defaultInput?.name ?? L10n.tr("No microphone"))
                        .font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    if audio.micUse.inUse || audio.cameraInUse { RecordingDot(size: 6) }
                }
                HStack(spacing: 6) {
                    Text(verbatim: detail).font(Theme.font(.s)).foregroundStyle(muted ? Theme.failed : Theme.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if hotkey.modifiers != 0 {
                        Text(verbatim: hotkey.description)
                            .font(Theme.font(.xs, .medium).monospacedDigit()).foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 6).frame(height: 15)
                            .background(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private var detail: String {
        if audio.micMuted { return L10n.tr("Mic muted") }
        if !audio.micMutable, audio.defaultInput != nil { return L10n.tr("Can't be muted") }
        if audio.micUse.inUse {
            return audio.micUse.apps.isEmpty ? L10n.tr("In use") : L10n.tr("In use by %@", audio.micUse.apps.joined(separator: ", "))
        }
        if audio.cameraInUse { return L10n.tr("Camera in use") }
        return L10n.tr("Microphone")
    }
}

/// Every output device; the current one checked, a click switches.
private struct OutputList: View {
    let audio: AudioCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: L10n.tr("Output").uppercased())
                .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 10)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(audio.outputs) { d in
                        OutputRow(device: d, current: d.id == audio.defaultOutputID) { audio.selectOutput(d.id) }
                    }
                }
            }
        }
    }
}

private struct OutputRow: View {
    let device: AudioDevice
    let current: Bool
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: device.symbol).font(.system(size: 11)).frame(width: 18)
                    .foregroundStyle(current ? Theme.primary : Theme.secondary)
                Text(verbatim: device.name).font(Theme.font(.m, current ? .semibold : .regular))
                    .foregroundStyle(current ? Theme.primary : Theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if current { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.done) }
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover && !current ? Theme.card : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
