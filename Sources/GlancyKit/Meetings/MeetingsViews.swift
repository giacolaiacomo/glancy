import AppKit
import SwiftUI

// MARK: Wing (collapsed, while recording): static, the minutes change once a minute

struct MeetingWingLeft: View {
    var body: some View {
        HStack(spacing: 5.ui) {
            Circle().fill(Theme.failed).frame(width: 7.ui, height: 7.ui)
            Image(systemName: MeetingsModule.symbol).font(.system(size: 10.ui, weight: .semibold)).foregroundStyle(Theme.primary)
        }
        .padding(.horizontal, 4.ui)
    }
}

struct MeetingWingRight: View {
    let model: MeetingsModel
    var body: some View {
        Text(verbatim: MeetingsText.minutes(model.minutes))
            .font(Theme.font(.s, .semibold).monospacedDigit())
            .foregroundStyle(Theme.failed)
            .lineLimit(1)
            .padding(.horizontal, 4.ui)
    }
}

// MARK: Drop-down: the question, then what became of it

/// "Record this meeting?" with Record / Not now; the same drop-down turns into "Recording · Stop"
/// once answered (a drop-down can't be taken back early) and says so when a recording began by itself.
struct MeetingPeek: View {
    let model: MeetingsModel
    let actions: MeetingActions

    var body: some View {
        HStack(spacing: 8.ui) {
            switch model.phase {
            case .offering:
                let question = L10n.tr("Record this meeting?"), record = L10n.tr("Record"), notNow = L10n.tr("Not now")
                let room = Self.titleRoom(question, pills: [record, notNow])
                Image(systemName: MeetingsModule.symbol).font(.system(size: 11.ui, weight: .semibold)).foregroundStyle(Theme.secondary)
                Text(verbatim: question).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                    .lineLimit(1)
                // The name only where it is more than a stub (Italian leaves it little room).
                if room >= 56 { title(min(room, 120)) }
                MeetingPeekPill(title: record, prominent: true, action: actions.record)
                MeetingPeekPill(title: notNow, action: actions.notNow)
            case .starting:
                Circle().fill(Theme.tertiary).frame(width: 7.ui, height: 7.ui)
                Text(verbatim: L10n.tr("Starting…")).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                title(120)
            case .recording:
                Circle().fill(Theme.failed).frame(width: 7.ui, height: 7.ui)
                Text(verbatim: L10n.tr("Recording")).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                title(120)
                MeetingPeekPill(title: L10n.tr("Stop"), prominent: true, action: actions.stop)
            case .idle:
                if model.notice == .cantHear || model.notice == .failed {
                    Image(systemName: "mic.slash").font(.system(size: 11.ui, weight: .semibold)).foregroundStyle(Theme.waiting)
                    Text(verbatim: L10n.tr("Glancy can't hear this meeting")).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                    MeetingPeekPill(title: L10n.tr("Open"), action: actions.openTab)
                } else if model.declined {
                    Image(systemName: MeetingsModule.symbol).font(.system(size: 11.ui, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    Text(verbatim: L10n.tr("Not recording")).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.secondary)
                } else {
                    Image(systemName: "checkmark").font(.system(size: 11.ui, weight: .semibold)).foregroundStyle(Theme.done)
                    Text(verbatim: L10n.tr("Recording saved")).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                }
            }
        }
        .padding(.horizontal, 12.ui)
        .fixedSize()
    }

    /// The meeting's name, at most `width` base points.
    private func title(_ width: CGFloat) -> some View {
        Text(verbatim: model.title).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: width.ui, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Base points left for the name once the question and the buttons are in: the drop-down is
    /// cut at its widest (content measured at its ideal width), so what doesn't fit would be lost.
    static func titleRoom(_ question: String, pills: [String]) -> CGFloat {
        func width(_ s: String, _ size: Theme.Size, _ weight: NSFont.Weight) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size.rawValue, weight: weight)]).width)
        }
        let limit = SurfaceLayout.peekEventMaxWidth - 2 * SurfaceLayout.peekEventPad - 2 * Theme.Base.closedTopRadius
        let pillsWidth = pills.reduce(0) { $0 + width($1, .s, .semibold) + 18 }
        // Padding 2×12, the symbol (~18), the question, the pills, a gap of 8 before each item.
        let fixed = 24 + 18 + width(question, .m, .semibold) + pillsWidth + CGFloat(pills.count + 2) * 8
        return limit - fixed - 4
    }
}

/// A button in a drop-down. The collapsed surface turns every click into "open the panel" before
/// SwiftUI sees it; a real NSView over the button gets its own clicks first.
struct MeetingPeekPill: View {
    let title: String
    var prominent = false
    let action: @MainActor () -> Void

    var body: some View {
        Text(verbatim: title)
            .font(Theme.font(.s, .semibold))
            .foregroundStyle(prominent ? Color.white : Theme.primary)
            .lineLimit(1)
            .padding(.horizontal, 9.ui)
            .frame(height: 20.ui)
            .background(Capsule().fill(prominent ? Theme.failed : Theme.card))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.hairline, lineWidth: 1.ui))
            .overlay(MeetingPeekClickTarget(action: action))
            .fixedSize()
            .accessibilityAddTraits(.isButton)
    }
}

private struct MeetingPeekClickTarget: NSViewRepresentable {
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

// MARK: Buttons (panel)

struct MeetingButton: View {
    enum Style { case plain, record, danger }
    let title: String
    var symbol: String?
    var style: Style = .plain
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5.ui) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.ui, weight: .bold)) }
                Text(verbatim: title).font(Theme.font(.s, .semibold)).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10.ui)
            .frame(height: 24.ui)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .plain: hover ? Theme.primary : Theme.secondary
        case .record: Color.white
        case .danger: Theme.failed
        }
    }

    private var background: Color {
        switch style {
        case .plain: hover ? Color.white.opacity(0.12) : Theme.card
        case .record: hover ? Theme.failed.opacity(0.85) : Theme.failed
        case .danger: Theme.failed.opacity(hover ? 0.22 : 0.14)
        }
    }
}

/// A small icon button in a row.
private struct RowIcon: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.ui, weight: .semibold))
                .foregroundStyle(tint ?? (hover ? Theme.primary : Theme.secondary))
                .frame(width: 22.ui, height: 22.ui)
                .background(Circle().fill(hover ? Color.white.opacity(0.10) : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct Caption: View {
    let text: String
    var color: Color = Theme.tertiary
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 9.5.ui, weight: .semibold)).tracking(0.6.ui)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A thin bar (no spinner: a closed notch never animates; this is drawn only in the panel).
private struct Bar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Theme.primary).frame(width: max(3.ui, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 3.ui)
    }
}

// MARK: Tab

struct MeetingsTabView: View {
    let module: MeetingsModule
    let model: MeetingsModel

    var body: some View {
        HStack(alignment: .top, spacing: 12.ui) {
            MeetingStatusCard(module: module, model: model)
                .frame(width: 236.ui)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 4.ui) {
                HStack(spacing: 6.ui) {
                    Text(verbatim: L10n.tr("Recordings")).font(Theme.font(.s, .semibold)).foregroundStyle(Theme.primary)
                    if !model.records.isEmpty {
                        Text(verbatim: "\(model.records.count)").font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 4.ui)
                    RowIcon(symbol: "folder", help: L10n.tr("Show in Finder")) { module.reveal() }
                }
                if model.records.isEmpty {
                    VStack(alignment: .leading, spacing: 3.ui) {
                        Text(verbatim: model.loaded || module.sample ? L10n.tr("No recordings yet") : "")
                            .font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                        Text(verbatim: L10n.tr("Audio and transcripts stay on this Mac."))
                            .font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                    }
                    .padding(.top, 4.ui)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2.ui) {
                            ForEach(model.records) { r in MeetingRow(module: module, model: model, record: r) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The left card: what is going on now and the one thing to do about it.
struct MeetingStatusCard: View {
    let module: MeetingsModule
    let model: MeetingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5.ui) {
            content
        }
        .padding(11.ui)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10.ui, style: .continuous).fill(Theme.card))
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 6.ui) {
                Circle().fill(Theme.failed).frame(width: 7.ui, height: 7.ui)
                Caption(text: L10n.tr("Recording"), color: Theme.failed)
                Spacer(minLength: 4.ui)
                if let start = model.started {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false).font(Theme.font(.l, .semibold).monospacedDigit()).foregroundStyle(Theme.primary)
                }
            }
            Text(verbatim: model.title).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(2)
            Text(verbatim: MeetingsText.tracks(model.tracks)).font(Theme.font(.s)).foregroundStyle(Theme.secondary).lineLimit(2)
            Spacer(minLength: 2.ui)
            HStack(spacing: 6.ui) {
                MeetingButton(title: L10n.tr("Stop"), symbol: "stop.fill", style: .record) { module.stopRecording() }
                MeetingButton(title: model.confirmingDiscard ? L10n.tr("Discard?") : L10n.tr("Discard"),
                              style: model.confirmingDiscard ? .danger : .plain) { module.discard() }
            }
        case .offering:
            Caption(text: model.detection?.app ?? L10n.tr("Meeting on"))
            Text(verbatim: L10n.tr("Record this meeting?")).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text(verbatim: model.title).font(Theme.font(.m)).foregroundStyle(Theme.secondary).lineLimit(2)
            Spacer(minLength: 2.ui)
            HStack(spacing: 6.ui) {
                MeetingButton(title: L10n.tr("Record"), symbol: "record.circle", style: .record) { module.record() }
                MeetingButton(title: L10n.tr("Not now")) { module.decline() }
            }
            Text(verbatim: L10n.tr("Let the others know you're recording.")).font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                .lineLimit(2)
        case .starting:
            Caption(text: L10n.tr("Starting…"))
            Text(verbatim: model.title).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(2)
            Text(verbatim: L10n.tr("Opening the microphone and system audio")).font(Theme.font(.s)).foregroundStyle(Theme.secondary)
                .lineLimit(2)
        case .idle:
            if model.notice == .cantHear || model.notice == .failed {
                Caption(text: L10n.tr("Can't record"), color: Theme.waiting)
                Text(verbatim: L10n.tr("Glancy can't hear this meeting")).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary)
                    .lineLimit(2)
                Text(verbatim: model.notice == .failed ? L10n.tr("The microphone and system audio would not open.")
                     : L10n.tr("Allow the microphone or system audio in System Settings."))
                    .font(Theme.font(.s)).foregroundStyle(Theme.secondary).lineLimit(3)
                Spacer(minLength: 2.ui)
                HStack(spacing: 6.ui) {
                    MeetingButton(title: L10n.tr("Open Settings")) {
                        NSWorkspace.shared.open(PermissionCenter.settingsURL(module.permissions.mic() == .granted ? .systemAudio : .microphone))
                    }
                    MeetingButton(title: L10n.tr("OK")) { module.dismissNotice() }
                }
            } else {
                Caption(text: module.settings.mode == .off ? L10n.tr("Not listening") : L10n.tr("Listening for calls"))
                Text(verbatim: L10n.tr("No meeting on")).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                Text(verbatim: MeetingsText.modeHint(module.settings.mode)).font(Theme.font(.s)).foregroundStyle(Theme.secondary)
                    .lineLimit(3)
                Spacer(minLength: 2.ui)
                MeetingButton(title: L10n.tr("Record now"), symbol: "record.circle", style: .record) { module.record() }
            }
        }
    }
}

/// One recording: play, title, when and how long, the transcript's state, folder, copy, delete.
struct MeetingRow: View {
    let module: MeetingsModule
    let model: MeetingsModel
    let record: MeetingRecord
    @State private var hover = false

    var body: some View {
        let playing = model.playing == record.id
        HStack(spacing: 8.ui) {
            RowIcon(symbol: playing ? "pause.fill" : "play.fill", help: playing ? L10n.tr("Pause") : L10n.tr("Play"),
                    tint: playing ? Theme.primary : nil) { module.togglePlay(record.id) }
            VStack(alignment: .leading, spacing: 1.ui) {
                Text(verbatim: record.title).font(Theme.font(.m, .medium)).foregroundStyle(Theme.primary).lineLimit(1)
                HStack(spacing: 4.ui) {
                    Text(verbatim: MeetingsText.when(record)).font(Theme.font(.s)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    status
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.confirmingDelete == record.id {
                MeetingButton(title: L10n.tr("Delete?"), style: .danger) { module.delete(record.id) }
            } else {
                if record.transcript == .done {
                    RowIcon(symbol: model.copied == record.id ? "checkmark" : "doc.on.doc", help: L10n.tr("Copy transcript")) {
                        module.copyTranscript(record.id)
                    }
                }
                RowIcon(symbol: "folder", help: L10n.tr("Show in Finder")) { module.reveal(record.id) }
                RowIcon(symbol: "trash", help: L10n.tr("Delete")) { module.delete(record.id) }
            }
        }
        .padding(.horizontal, 4.ui)
        .padding(.vertical, 3.ui)
        .background(RoundedRectangle(cornerRadius: 7.ui, style: .continuous).fill(hover || playing ? Theme.card : Color.clear))
        .onHover { hover = $0 }
    }

    @ViewBuilder private var status: some View {
        if let p = model.progress[record.id] {
            Text(verbatim: "·").font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
            Text(verbatim: L10n.tr("Transcript %d%%", Int((p * 100).rounded(.down)))).font(Theme.font(.s).monospacedDigit())
                .foregroundStyle(Theme.secondary).lineLimit(1)
            Bar(value: p).frame(width: 40.ui)
        } else {
            switch record.transcript {
            case .done, .empty, .unavailable:
                Text(verbatim: "·").font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                Text(verbatim: MeetingsText.state(record)).font(Theme.font(.s)).foregroundStyle(Theme.tertiary).lineLimit(1)
            case .pending, .failed, .needsPermission:
                Text(verbatim: "·").font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                Button { module.transcribe(record.id) } label: {
                    Text(verbatim: MeetingsText.state(record)).font(Theme.font(.s, .semibold))
                        .foregroundStyle(record.transcript == .pending ? Theme.secondary : Theme.waiting).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: Home

struct MeetingsHomeCard: View {
    let module: MeetingsModule
    let model: MeetingsModel

    // Two rows: what is going on (and for how long), then the meeting with its buttons. A Home
    // card is half the panel: one row would leave the title a few letters. Discard lives in the tab.
    var body: some View {
        VStack(alignment: .leading, spacing: 3.ui) {
            HStack(spacing: 5.ui) {
                if model.phase == .recording {
                    Circle().fill(Theme.failed).frame(width: 6.ui, height: 6.ui)
                } else {
                    Image(systemName: MeetingsModule.symbol).font(.system(size: 9.ui, weight: .semibold)).foregroundStyle(Theme.tertiary)
                }
                HomeCaption(text: caption)
                // Whole minutes, as on the wing (changed once a minute): a counting text here would
                // keep Home in the window, animating, when the panel opens straight onto another tab.
                if model.phase == .recording {
                    Text(verbatim: MeetingsText.minutes(model.minutes)).font(Theme.font(.xs, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            HStack(spacing: 6.ui) {
                Text(verbatim: headline).font(Theme.font(.l, .medium)).foregroundStyle(Theme.primary).lineLimit(1)
                Spacer(minLength: 6.ui)
                switch model.phase {
                case .recording:
                    MeetingButton(title: L10n.tr("Stop"), symbol: "stop.fill", style: .record) { module.stopRecording() }
                case .offering:
                    MeetingButton(title: L10n.tr("Not now")) { module.decline() }
                    MeetingButton(title: L10n.tr("Record"), symbol: "record.circle", style: .record) { module.record() }
                case .starting:
                    EmptyView()
                case .idle:
                    if model.notice != nil { MeetingButton(title: L10n.tr("OK")) { module.dismissNotice() } }
                }
            }
            if model.phase == .idle, model.notice == nil, case let (id, p)? = model.progress.first {
                HStack(spacing: 6.ui) {
                    Text(verbatim: L10n.tr("Transcript %d%%", Int((p * 100).rounded(.down)))).font(Theme.font(.s).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                    Bar(value: p).frame(width: 60.ui)
                }
                .id(id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var caption: String {
        switch model.phase {
        case .recording: L10n.tr("Recording")
        case .offering: L10n.tr("Record this meeting?")
        case .starting: L10n.tr("Starting…")
        case .idle: model.notice != nil ? L10n.tr("Can't record") : L10n.tr("Writing the transcript")
        }
    }

    private var headline: String {
        if model.phase == .idle {
            if model.notice != nil { return L10n.tr("Glancy can't hear this meeting") }
            if let id = model.progress.keys.first, let r = model.record(id) { return r.title }
        }
        return model.title
    }
}

/// Home at rest (Always): the last recording, with Play.
struct MeetingsIdleCard: View {
    let module: MeetingsModule
    let model: MeetingsModel
    let record: MeetingRecord

    var body: some View {
        HomeIdleRow(symbol: MeetingsModule.symbol, caption: L10n.tr("Last recording"), title: record.title,
                    detail: MeetingsText.when(record), open: { module.actions.openTab() }) {
            RowIcon(symbol: model.playing == record.id ? "pause.fill" : "play.fill",
                    help: model.playing == record.id ? L10n.tr("Pause") : L10n.tr("Play")) { module.togglePlay(record.id) }
        }
    }
}
