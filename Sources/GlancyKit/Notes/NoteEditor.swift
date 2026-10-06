import AppKit
import SwiftUI

/// The note editor: a plain NSTextView (undo, spelling, every text shortcut) with two niceties —
/// checklist lines draw a box you can click, and Return continues a list.
struct NoteEditor: NSViewRepresentable {
    let model: NotesModel
    let noteID: String
    let text: String
    let focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let tv = NoteTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.insertionPointColor = .white
        tv.textContainerInset = NSSize(width: 6.ui, height: 8.ui)
        tv.font = NoteStyle.font
        tv.typingAttributes = NoteStyle.base
        tv.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.22)]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 2
        tv.delegate = context.coordinator
        scroll.documentView = tv
        context.coordinator.textView = tv
        load(tv, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        // A different note, or the text changed from outside (Home card toggle, the command bar).
        if context.coordinator.noteID != noteID || (tv.string != text && !context.coordinator.editing) {
            load(tv, context: context)
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            focus(tv)
        }
    }

    private func load(_ tv: NoteTextView, context: Context) {
        context.coordinator.noteID = noteID
        context.coordinator.focusToken = focusToken
        tv.string = text
        tv.undoManager?.removeAllActions()
        tv.restyle()
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        focus(tv)
    }

    /// Cursor at the end once the panel can take the keyboard (it becomes key a beat after the tab
    /// asks for it).
    private func focus(_ tv: NoteTextView) {
        DispatchQueue.main.async { [weak tv] in
            guard let tv, let window = tv.window else { return }
            window.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: NotesModel
        weak var textView: NoteTextView?
        var noteID: String?
        var focusToken = 0
        var editing = false

        init(model: NotesModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView, let id = noteID else { return }
            tv.restyle()
            editing = true
            model.edit(id, text: tv.string)
            editing = false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), textView.selectedRange().length == 0 else { return false }
            let caret = textView.selectedRange().location
            switch Checklist.continuation(in: textView.string, caret: caret) {
            case .insert(let s):
                textView.insertText(s, replacementRange: textView.selectedRange())
                return true
            case .endList(let r):
                textView.insertText("", replacementRange: r)
                return true
            case nil:
                return false
            }
        }
    }
}

/// Text attributes of the editor, at the chosen size (Settings → General → Size).
@MainActor
enum NoteStyle {
    static var font: NSFont { NSFont.systemFont(ofSize: 12.5.ui) }
    static let ink = NSColor.white.withAlphaComponent(0.92)
    static let done = NSColor.white.withAlphaComponent(0.38)
    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2.5.ui
        return p
    }
    static var base: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph] }
    static var heading: NSFont { NSFont.systemFont(ofSize: 14.ui, weight: .semibold) }
    /// The dash and space before a box shrink to almost nothing: the box starts the line.
    static let tiny = NSFont.systemFont(ofSize: 1)
}

/// NSTextView with clickable checklist boxes drawn over the `[ ]` characters (which are made
/// invisible), done items struck through, `#` headings in bold.
final class NoteTextView: NSTextView {
    private var markers: [Checklist.Marker] = []

    /// Re-applies the light styling to the whole note (notes are short).
    func restyle() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        markers = Checklist.markers(in: string)
        storage.beginEditing()
        storage.setAttributes(NoteStyle.base, range: full)
        let ns = string as NSString
        ns.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            if range.length > 1, ns.character(at: range.location) == 0x23 {   // "#"
                storage.addAttribute(.font, value: NoteStyle.heading, range: range)
            }
        }
        for m in markers {
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: m.prefix)
            let lead = NSRange(location: m.prefix.location, length: m.box.location - m.prefix.location)
            storage.addAttribute(.font, value: NoteStyle.tiny, range: lead)
            if m.checked {
                let rest = NSRange(location: NSMaxRange(m.box), length: NSMaxRange(m.line) - NSMaxRange(m.box))
                if rest.length > 0 {
                    storage.addAttributes([.foregroundColor: NoteStyle.done, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                           .strikethroughColor: NoteStyle.done], range: rest)
                }
            }
        }
        storage.endEditing()
        typingAttributes = NoteStyle.base
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let m = marker(at: p), shouldChangeText(in: m.box, replacementString: m.checked ? "[ ]" : "[x]") {
            textStorage?.replaceCharacters(in: m.box, with: m.checked ? "[ ]" : "[x]")
            didChangeText()
            return
        }
        super.mouseDown(with: event)
    }

    /// The checklist box under a point (generous: the box plus a little around it).
    private func marker(at p: NSPoint) -> Checklist.Marker? {
        for m in markers {
            if boxRect(m).insetBy(dx: -4, dy: -3).contains(p) { return m }
        }
        return nil
    }

    private func boxRect(_ m: Checklist.Marker) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let glyphs = lm.glyphRange(forCharacterRange: m.box, actualCharacterRange: nil)
        let r = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let side: CGFloat = 12.ui
        // Centre on the line's text (the line fragment includes the line spacing below).
        let lineFont = NoteStyle.font
        let midY = r.minY + (lineFont.ascender - lineFont.descender) / 2 + 0.5
        return NSRect(x: r.minX + 0.5, y: midY - side / 2, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for m in markers {
            let r = boxRect(m)
            guard r.intersects(dirtyRect) else { continue }
            // Drawn for a 12 pt box, scaled with it (`k`) at a larger size.
            let k = r.width / 12
            let path = NSBezierPath(roundedRect: r, xRadius: 3.5 * k, yRadius: 3.5 * k)
            if m.checked {
                NSColor.white.withAlphaComponent(0.8).setFill()
                path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: r.minX + 3 * k, y: r.midY + 0.2 * k))
                tick.line(to: NSPoint(x: r.minX + 5.2 * k, y: r.maxY - 3 * k))
                tick.line(to: NSPoint(x: r.maxX - 2.8 * k, y: r.minY + 3.2 * k))
                tick.lineWidth = 1.6 * k
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                NSColor.black.setStroke()
                tick.stroke()
            } else {
                NSColor.white.withAlphaComponent(0.5).setStroke()
                path.lineWidth = 1.2 * k
                path.stroke()
            }
        }
    }
}
