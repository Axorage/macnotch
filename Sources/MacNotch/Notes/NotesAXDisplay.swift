import AppKit

/// Builds the editor text for an Accessibility-backed note. The characters ALWAYS come from Notes' own AX text
/// (so editor offsets equal Notes' offsets); styling is borrowed from the note's HTML only when the HTML decodes to
/// exactly the same text. Attachments (U+FFFC) become small non-editable "photo" chips.
enum NoteAXDisplay {
    static let placeholder = "\u{FFFC}"

    static func attributed(baseline: String, html: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: baseline, attributes: NoteHTML.baseAttributes)
        if let styled = htmlStyled(html, matching: baseline) {
            let n = min(styled.length, out.length)
            styled.enumerateAttributes(in: NSRange(location: 0, length: n)) { attrs, r, _ in
                out.setAttributes(attrs, range: r)
            }
        }
        // Back to front so earlier offsets stay valid (each chip is one character, like the U+FFFC it replaces).
        let ns = baseline as NSString
        var i = ns.length
        while i > 0 {
            let r = ns.range(of: placeholder, options: .backwards, range: NSRange(location: 0, length: i))
            if r.location == NSNotFound { break }
            let chip = NSMutableAttributedString(attachment: chipAttachment())
            if let base = out.attributes(at: r.location, effectiveRange: nil) as [NSAttributedString.Key: Any]? {
                chip.addAttributes(base.filter { $0.key != .attachment && $0.key != .link }, range: NSRange(location: 0, length: chip.length))
            }
            out.replaceCharacters(in: r, with: chip)
            i = r.location
        }
        return out
    }

    /// Paragraph / run styling from the HTML, markers excluded (Notes' AX text has none); nil unless the text is identical.
    static func stylingMatches(baseline: String, html: String) -> Bool { htmlStyled(html, matching: baseline) != nil }

    private static func htmlStyled(_ html: String, matching baseline: String) -> NSAttributedString? {
        let tolerant = NoteHTML.stripImages(html)
        guard tolerant.utf16.count <= NoteHTML.maxHTMLParseLength else { return nil }
        guard let paras = NoteHTML.parseParagraphs(tolerant) else { return nil }
        let out = NSMutableAttributedString()
        for (i, p) in paras.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: NoteHTML.baseAttributes)) }
            for (t, st) in p.runs {
                var a = st.attributes
                a[.paragraphStyle] = NoteHTML.paragraphStyle(list: false)
                out.append(NSAttributedString(string: t, attributes: a))
            }
        }
        // Only trailing newlines may differ (Notes' text ends with one more or less), so offsets agree.
        func trimmed(_ s: String) -> String {
            var t = s.replacingOccurrences(of: "\u{A0}", with: " ")
            while t.hasSuffix("\n") { t.removeLast() }
            return t
        }
        return trimmed(out.string) == trimmed(baseline) ? out : nil
    }

    private static func chipAttachment() -> NSTextAttachment {
        let att = NSTextAttachment()
        let cfg = NSImage.SymbolConfiguration(pointSize: Typo.noteChipSymbolSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NoteHTML.dimColor]))
        if let img = NSImage(systemSymbolName: "photo", accessibilityDescription: "Attachment")?.withSymbolConfiguration(cfg) {
            att.image = img
            att.bounds = CGRect(x: 0, y: -1.5, width: img.size.width, height: img.size.height)
        }
        return att
    }
}
