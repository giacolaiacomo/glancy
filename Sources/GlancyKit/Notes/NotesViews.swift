import AppKit
import SwiftUI

/// What the views ask the module to do beyond the model.
@MainActor
struct NotesActions {
    var openInNotes: (Note) -> Void = { _ in }
    var copied: () -> Void = {}
}

// MARK: Tab

/// A mini Notes: the list (search + new) on the left, the editor on the right.
struct NotesTabView: View {
    let model: NotesModel
    let actions: NotesActions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NotesList(model: model)
                .frame(width: 162)
            VStack(spacing: 4) {
                if let note = model.selected {
                    NoteToolbar(model: model, note: note, actions: actions)
                    NoteEditor(model: model, noteID: note.id, text: note.text, focusToken: model.focusToken)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    NotesEmpty(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct NotesList: View {
    let model: NotesModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                    TextField("", text: Bindable(model).query,
                              prompt: Text(verbatim: L10n.tr("Search")).foregroundStyle(Theme.tertiary))
                        .textFieldStyle(.plain)
                        .font(Theme.font(.s))
                        .foregroundStyle(Theme.primary)
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Capsule().fill(Theme.card))
                NotesIconButton(symbol: "square.and.pencil", label: L10n.tr("New note")) { model.create() }
            }
            let list = model.listed
            if list.isEmpty, !model.query.isEmpty {
                Text(verbatim: L10n.tr("No matches"))
                    .font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        ForEach(list) { note in
                            NoteRow(note: note, selected: note.id == model.selectedID,
                                    pinned: note.id == model.settings.pinnedID) { model.select(note.id) }
                        }
                    }
                }
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    let pinned: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(verbatim: note.title ?? L10n.tr("New note"))
                        .font(Theme.font(.s, .semibold))
                        .foregroundStyle(note.title == nil ? Theme.tertiary : Theme.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Theme.tertiary)
                    }
                }
                HStack(spacing: 5) {
                    Text(verbatim: NotesFormat.short(note.modified))
                        .foregroundStyle(Theme.secondary)
                    Text(verbatim: note.bodyLines.first ?? "")
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                .font(Theme.font(.xs))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : hover ? Theme.card : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct NoteToolbar: View {
    let model: NotesModel
    let note: Note
    let actions: NotesActions

    var body: some View {
        HStack(spacing: 2) {
            Text(verbatim: L10n.tr("Edited %@", NotesFormat.short(note.modified)))
                .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 4)
            NotesIconButton(symbol: "checklist", label: L10n.tr("Add a checklist item")) { addChecklistItem() }
            let pinned = model.settings.pinnedID == note.id
            NotesIconButton(symbol: pinned ? "pin.fill" : "pin", label: L10n.tr(pinned ? "Unpin from Home" : "Pin to Home"),
                            on: pinned) { model.togglePin(note.id) }
            Menu {
                Button(L10n.tr("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.text, forType: .string)
                    actions.copied()
                }
                ShareLink(item: note.text) { Text(verbatim: L10n.tr("Share…")) }
                Divider()
                Button(L10n.tr("Open in Notes")) { actions.openInNotes(note) }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.secondary)
            .frame(width: 26, height: 22)
            .help(L10n.tr("Send to…"))
            .disabled(note.isBlank)
            if model.confirmingDelete {
                Button { model.delete(note.id) } label: {
                    Text(verbatim: L10n.tr("Delete?"))
                        .font(Theme.font(.xs, .semibold)).foregroundStyle(Theme.failed)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Capsule().fill(Theme.failed.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else {
                NotesIconButton(symbol: "trash", label: L10n.tr("Delete note")) { model.confirmingDelete = true }
            }
        }
        .frame(height: 22)
    }

    /// A new "- [ ] " line at the end of the note, keyboard in the editor.
    private func addChecklistItem() {
        var text = note.text
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        model.edit(note.id, text: text + "- [ ] ")
        model.focusToken &+= 1
    }
}

private struct NotesEmpty: View {
    let model: NotesModel
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.tertiary)
            Text(verbatim: L10n.tr("No notes yet")).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.secondary)
            NotchTextButton(L10n.tr("New note")) { model.create() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NotesIconButton: View {
    let symbol: String
    let label: String
    var on = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on || hover ? Theme.primary : Theme.secondary)
                .frame(width: 26, height: 22)
                .background(Capsule().fill(hover ? Theme.card : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: Home

/// The pinned note on Home: its title and first lines; checklist boxes can be ticked right here.
struct NotesHomeCard: View {
    let model: NotesModel
    let note: Note
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: open) {
                HStack(spacing: 5) {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                    Text(verbatim: note.title ?? L10n.tr("New note"))
                        .font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ForEach(Array(NotesFormat.previewLines(note.text, max: 3).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 5) {
                    if let box = line.box {
                        Button { model.toggleCheck(note.id, at: box) } label: {
                            Image(systemName: line.checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 10)).foregroundStyle(line.checked ? Theme.tertiary : Theme.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(verbatim: line.text)
                        .font(Theme.font(.s))
                        .foregroundStyle(line.checked ? Theme.tertiary : Theme.secondary)
                        .strikethrough(line.checked, color: Theme.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: Formatting

enum NotesFormat {
    /// "14:32" today, "Yesterday", "Mon", "5 Oct".
    @MainActor static func short(_ d: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = L10n.locale
        if cal.isDate(d, inSameDayAs: now) {
            f.timeStyle = .short; f.dateStyle = .none
            return f.string(from: d)
        }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return L10n.tr("Yesterday") }
        if now.timeIntervalSince(d) < 6 * 86_400 {
            f.setLocalizedDateFormatFromTemplate("EEE")
            return f.string(from: d)
        }
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: d)
    }

    struct PreviewLine { var text: String; var checked: Bool; var box: Int? }

    /// The lines after the title for the Home card; checklist lines carry their box offset.
    static func previewLines(_ text: String, max: Int) -> [PreviewLine] {
        let ns = text as NSString
        let markers = Dictionary(Checklist.markers(in: text).map { ($0.line.location, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PreviewLine] = []
        var first = true
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { sub, range, _, stop in
            let plain = Note.plain(sub ?? "")
            guard !plain.isEmpty else { return }
            if first { first = false; return }   // the title
            let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
            if let m = markers[lineStart] {
                out.append(PreviewLine(text: plain, checked: m.checked, box: m.box.location))
            } else {
                out.append(PreviewLine(text: plain, checked: false, box: nil))
            }
            if out.count >= max { stop.pointee = true }
        }
        return out
    }
}
