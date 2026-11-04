import SwiftUI
import AppKit

/// Rich-text editor for a note body: white on black, system font 12, undo enabled. Formatting is limited to what
/// Notes HTML can carry (bold, italic, underline, strikethrough, links, headings, monospace, bullet / numbered lists).
/// Lighter than TextEditor and exposes the selection (used to find the line for "Edit in Notes").
struct NoteTextEditor: NSViewRepresentable {
    @ObservedObject var session: NoteEditSession
    /// Esc pressed in the editor (routed to NotchViewModel.handleKey so there is one code path).
    var onEscape: () -> Void
    /// Take keyboard focus as soon as the editor is on screen (the user just clicked this note open).
    var autoFocus = false
    /// Caret to restore after the text is first loaded.
    var initialCaret = 0

    func makeCoordinator() -> Coordinator { Coordinator(session: session, initialCaret: initialCaret) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let tv = IslandTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: Space.s, height: 2)

        tv.isRichText = true
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.usesInspectorBar = false
        tv.importsGraphics = false
        tv.allowsImageEditing = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.insertionPointColor = .white
        tv.wantsAutoFocus = autoFocus
        tv.focusRingType = .none
        // Notes text must round-trip unchanged: no smart substitutions, no spelling squiggles.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.28),
                                     .foregroundColor: NSColor.white]
        tv.linkTextAttributes = [.foregroundColor: NSColor(calibratedRed: 0.45, green: 0.72, blue: 1, alpha: 1),
                                 .underlineStyle: NSUnderlineStyle.single.rawValue]
        tv.setAccessibilityLabel("Note text")
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        scroll.documentView = tv
        context.coordinator.replaceText(session.attributed, token: session.reloadToken)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        tv.onEscape = onEscape
        tv.textOnly = session.backing == .accessibility
        if context.coordinator.token != session.reloadToken {
            context.coordinator.replaceText(session.attributed, token: session.reloadToken)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: NoteEditSession
        weak var textView: IslandTextView?
        var token = -1
        var pendingCaret: Int?
        /// Range of text typed / pasted by the last change (cleared of any inherited list-marker attribute).
        private var pendingInsert: NSRange?
        init(session: NoteEditSession, initialCaret: Int) { self.session = session; pendingCaret = initialCaret > 0 ? initialCaret : nil }

        func replaceText(_ a: NSAttributedString, token: Int) {
            guard let tv = textView else { return }
            self.token = token
            tv.textStorage?.setAttributedString(a)
            tv.typingAttributes = NoteHTML.baseAttributes
            tv.undoManager?.removeAllActions()
            let loc = min(pendingCaret ?? 0, a.length)
            pendingCaret = nil
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
            session.selection = tv.selectedRange()
        }

        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Accessibility-backed notes: attachments (U+FFFC chips) are Notes' own, never touched from here.
            if session.backing == .accessibility {
                let ns = tv.string as NSString
                let end = min(NSMaxRange(range), ns.length)
                let hitsChip = range.location < end
                    && ns.range(of: NoteAXDisplay.placeholder, options: [], range: NSRange(location: range.location, length: end - range.location)).location != NSNotFound
                if hitsChip || (replacementString?.contains(NoteAXDisplay.placeholder) ?? false) {
                    NSSound.beep()
                    return false
                }
            }
            if let r = replacementString, !(tv as? IslandTextView)!.internalEdit {
                pendingInsert = NSRange(location: range.location, length: (r as NSString).length)
            } else { pendingInsert = nil }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
            if let r = pendingInsert, r.length > 0, NSMaxRange(r) <= storage.length {
                storage.removeAttribute(.nMarker, range: r)
                NoteHTML.restyle(storage, range: r)
            }
            pendingInsert = nil
            let sel = tv.selectedRange()
            let fixed = NoteHTML.normalizeMarkers(storage, selection: sel)
            if fixed != sel { tv.setSelectedRange(fixed) }
            session.contentChanged(NSAttributedString(attributedString: storage))
            session.selection = tv.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            session.selection = tv.selectedRange()
            if tv.typingAttributes[.nMarker] != nil {
                var t = tv.typingAttributes
                t.removeValue(forKey: .nMarker)
                tv.typingAttributes = NoteHTML.baseAttributes.merging(NoteStyle(attrs: t).attributes) { _, n in n }
            }
        }

        /// The caret never sits inside a list marker.
        func textView(_ tv: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
            guard new.length == 0, let s = tv.textStorage, new.location <= s.length else { return new }
            let ns = s.string as NSString
            let para = ns.paragraphRange(for: NSRange(location: new.location, length: 0))
            var end = NSMaxRange(para)
            if end > para.location, ns.character(at: end - 1) == 0x0A { end -= 1 }
            let ml = NoteHTML.markerInfo(s, paraStart: para.location, paraEnd: end).length
            guard ml > 0, new.location < para.location + ml else { return new }
            let contentStart = para.location + ml
            if old.length == 0, old.location == contentStart, para.location > 0 {
                return NSRange(location: para.location - 1, length: 0)
            }
            return NSRange(location: contentStart, length: 0)
        }

        func textView(_ tv: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }
    }
}

/// NSTextView for the borderless panel. The panel has no Edit or Format menu, so the standard editing and
/// formatting shortcuts are handled here. Esc is forwarded; Command-S is handled by the panel through
/// NotchViewModel.handleKey.
final class IslandTextView: NSTextView {
    var onEscape: () -> Void = {}
    var wantsAutoFocus = false
    /// Notes-backed editing: text only. Formatting shortcuts do nothing (formatting is preserved in Notes).
    var textOnly = false
    /// True while this view inserts list markers itself (so the coordinator keeps their marker attribute).
    var internalEdit = false
    private var didAutoFocus = false

    override var acceptsFirstResponder: Bool { isEditable || isSelectable }

    /// Clicking into the editor is what asks the (non-activating) panel for key status.
    override func mouseDown(with event: NSEvent) {
        if let panel = window as? NotchPanel { MainActor.assumeIsolated { panel.focusEditor(self, reason: "click") } }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        Log.notes.notice("textView.becomeFirstResponder -> \(ok) editable=\(self.isEditable) isKey=\(self.window?.isKeyWindow ?? false)")
        if ok { updateInsertionPointStateAndRestartTimer(true); needsDisplay = true }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsAutoFocus, !didAutoFocus, let panel = window as? NotchPanel else { return }
        didAutoFocus = true
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.window === panel else { return }
            MainActor.assumeIsolated { panel.focusEditor(self, reason: "open") }
        }
    }

    override func keyDown(with event: NSEvent) {
        Log.notes.notice("textView.keyDown code=\(event.keyCode) chars=\(event.characters ?? "", privacy: .private) keyWindow=\(self.window?.isKeyWindow ?? false) appActive=\(NSApp.isActive)")
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onEscape() }

    // Only plain text may be dropped; pasting is sanitized in `paste`.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if flags == .command {
            switch key {
            case "x": cut(self); return true
            case "c": copy(self); return true
            case "v": paste(self); return true
            case "a": selectAll(self); return true
            case "z": undoManager?.undo(); return true
            case "b": formatOrRefuse(.bold); return true
            case "i": formatOrRefuse(.italic); return true
            case "u": formatOrRefuse(.underline); return true
            default: return false
            }
        }
        switch key {
        case "z": undoManager?.redo(); return true
        case "x": formatOrRefuse(.strike); return true
        case "v": pasteAsPlainText(self); return true
        default: return false
        }
    }

    // MARK: Formatting

    private func formatOrRefuse(_ f: NoteHTML.Format) {
        if textOnly { NSSound.beep() } else { toggleFormat(f) }
    }

    func toggleFormat(_ f: NoteHTML.Format) {
        guard let storage = textStorage else { return }
        let r = selectedRange()
        if r.length == 0 {
            let st = NoteStyle(attrs: typingAttributes)
            var t = NoteHTML.set(f, !NoteHTML.isOn(f, st), in: st).attributes
            t[.paragraphStyle] = typingAttributes[.paragraphStyle] ?? NoteHTML.paragraphStyle(list: false)
            typingAttributes = t
            return
        }
        guard shouldChangeText(in: r, replacementString: nil) else { return }
        NoteHTML.toggle(f, in: storage, range: r)
        didChangeText()
    }

    /// Replaces a range with attributed content as one undoable change.
    private func replace(_ range: NSRange, with a: NSAttributedString, marker: Bool = false) {
        guard let storage = textStorage else { return }
        internalEdit = marker
        defer { internalEdit = false }
        guard shouldChangeText(in: range, replacementString: a.string) else { return }
        storage.replaceCharacters(in: range, with: a)
        setSelectedRange(NSRange(location: range.location + a.length, length: 0))
        didChangeText()
    }

    // MARK: Paste (keeps bold / italic / underline / strike / monospace / links only)

    override func paste(_ sender: Any?) {
        if textOnly { pasteAsPlainText(sender); return }
        let pb = NSPasteboard.general
        var rich: NSAttributedString?
        if let d = pb.data(forType: .rtf) {
            rich = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        } else if let d = pb.data(forType: .html) {
            rich = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.html,
                                                              .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        }
        if let rich, rich.length > 0 {
            replace(selectedRange(), with: NoteHTML.sanitize(rich))
        } else {
            pasteAsPlainText(sender)
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
        var st = NoteStyle(attrs: typingAttributes)
        st.link = nil
        replace(selectedRange(), with: NSAttributedString(string: NoteHTML.cleanText(s), attributes: st.attributes))
    }

    // MARK: Lists and headings

    private func paragraphInfo(at loc: Int) -> (para: NSRange, end: Int, kind: String?, markerLength: Int)? {
        guard let s = textStorage else { return nil }
        let ns = s.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
        var end = NSMaxRange(para)
        if end > para.location, ns.character(at: end - 1) == 0x0A { end -= 1 }
        let (k, ml) = NoteHTML.markerInfo(s, paraStart: para.location, paraEnd: end)
        return (para, end, k, ml)
    }

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        if let p = paragraphInfo(at: sel.location), let kind = p.kind {
            let contentStart = p.para.location + p.markerLength
            if sel.length == 0, p.end == contentStart {
                // Return on an empty item ends the list.
                replace(NSRange(location: p.para.location, length: p.markerLength), with: NSAttributedString())
                typingAttributes = NoteHTML.baseAttributes
                return
            }
            let ins = NSMutableAttributedString(string: "\n", attributes: NoteHTML.baseAttributes)
            ins.append(NoteHTML.markerString(kind, number: 1))
            replace(NSRange(location: max(sel.location, contentStart), length: sel.length), with: ins, marker: true)
            typingAttributes = NoteHTML.baseAttributes
            return
        }
        super.insertNewline(sender)
        // After a title / heading line the next line is body text.
        let caret = selectedRange().location
        let ns = string as NSString
        if NoteStyle(attrs: typingAttributes).heading > 0, caret >= ns.length || ns.character(at: caret) == 0x0A {
            typingAttributes = NoteHTML.baseAttributes
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, let p = paragraphInfo(at: sel.location), p.kind != nil, sel.location == p.para.location + p.markerLength {
            // Backspace at the start of a list item turns it into a plain paragraph.
            replace(NSRange(location: p.para.location, length: p.markerLength), with: NSAttributedString())
            typingAttributes = NoteHTML.baseAttributes
            return
        }
        super.deleteBackward(sender)
    }
}
