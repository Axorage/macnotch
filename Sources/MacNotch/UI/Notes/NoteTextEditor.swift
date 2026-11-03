import SwiftUI
import AppKit

/// Plain-text editor for a note body: white on black, system font 13, no rich text, undo enabled.
/// Lighter than TextEditor and exposes the selection (used to find the line for "Edit in Notes").
struct NoteTextEditor: NSViewRepresentable {
    @ObservedObject var session: NoteEditSession
    /// Esc pressed in the editor (routed to NotchViewModel.handleKey so there is one code path).
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

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

        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsImageEditing = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.insertionPointColor = .white
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
        tv.setAccessibilityLabel("Note text")
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        scroll.documentView = tv
        context.coordinator.replaceText(session.text, token: session.reloadToken)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        tv.onEscape = onEscape
        if context.coordinator.token != session.reloadToken {
            context.coordinator.replaceText(session.text, token: session.reloadToken)
        }
    }

    static let attributes: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white, .paragraphStyle: p]
    }()

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: NoteEditSession
        weak var textView: IslandTextView?
        var token = -1
        init(session: NoteEditSession) { self.session = session }

        func replaceText(_ s: String, token: Int) {
            guard let tv = textView else { return }
            self.token = token
            tv.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: NoteTextEditor.attributes))
            tv.typingAttributes = NoteTextEditor.attributes
            tv.undoManager?.removeAllActions()
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            session.selection = tv.selectedRange()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            session.textChanged(tv.string)
            session.selection = tv.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            session.selection = tv.selectedRange()
        }
    }
}

/// NSTextView for the borderless panel. The panel has no Edit menu, so the standard editing shortcuts are
/// handled here. Esc is forwarded; Command-S is handled by the panel through NotchViewModel.handleKey.
final class IslandTextView: NSTextView {
    var onEscape: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { onEscape() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if flags == .command {
            switch key {
            case "x": cut(self); return true
            case "c": copy(self); return true
            case "v": pasteAsPlainText(self); return true
            case "a": selectAll(self); return true
            case "z": undoManager?.undo(); return true
            default: return false
            }
        }
        if key == "z" { undoManager?.redo(); return true }
        return false
    }
}
