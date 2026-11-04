import Foundation
import AppKit

// Rich-text codec between the HTML Notes stores in `body` and the attributed string shown in the notch editor.
//
// Setting `body` replaces the whole note, so this is deliberately conservative: a note is editable only when
// every tag in its HTML is on a small allowlist, the text decoded from it equals Notes' own `plaintext`, and a
// full round trip (parse, serialize, parse) reproduces the same text and formatting. Anything else (tables,
// images, checklists, unknown tags, colors, soft line breaks, nested lists, ...) is read-only.

extension NSAttributedString.Key {
    static let nBold = NSAttributedString.Key("macnotch.bold")
    static let nItalic = NSAttributedString.Key("macnotch.italic")
    static let nMono = NSAttributedString.Key("macnotch.mono")
    /// 1 = Notes "Title" (24 px), 2 = "Heading" (18 px). Always implies bold.
    static let nHeading = NSAttributedString.Key("macnotch.heading")
    /// "ul" / "ol" on the list marker characters ("•\t", "1.\t") at the start of a list paragraph.
    static let nMarker = NSAttributedString.Key("macnotch.marker")
}

/// Semantic formatting of a run. The display attributes (font, color) are derived from it.
struct NoteStyle: Equatable {
    var bold = false, italic = false, underline = false, strike = false, mono = false
    var heading = 0
    var link: String?

    init() {}

    init(attrs: [NSAttributedString.Key: Any]) {
        bold = (attrs[.nBold] as? Bool) == true
        italic = (attrs[.nItalic] as? Bool) == true
        mono = (attrs[.nMono] as? Bool) == true
        heading = attrs[.nHeading] as? Int ?? 0
        underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        if let s = attrs[.link] as? String { link = s } else if let u = attrs[.link] as? URL { link = u.absoluteString }
        if heading > 0 { bold = true }
    }

    /// Semantic + display attributes (white on black, system 13).
    var attributes: [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: NoteHTML.font(for: self), .foregroundColor: NoteHTML.textColor]
        if bold || heading > 0 { a[.nBold] = true }
        if italic { a[.nItalic] = true }
        if mono { a[.nMono] = true }
        if heading > 0 { a[.nHeading] = heading }
        if underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link { a[.link] = link }
        return a
    }

    fileprivate var signature: String {
        "\(bold || heading > 0 ? "b" : "")\(italic ? "i" : "")\(underline ? "u" : "")\(strike ? "s" : "")\(mono ? "m" : "")\(heading)\(link.map { "@" + $0 } ?? "")"
    }
}

enum NoteHTML {
    /// Why the last parse / check refused a note (tags and attribute names only, never note text).
    /// Written under `lock` because probes can run off the main actor.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _failure = ""
    static var lastFailure: String { lock.lock(); defer { lock.unlock() }; return _failure }
    private static func note(_ why: String) { lock.lock(); _failure = why; lock.unlock() }
    private static func bad<T>(_ why: String) -> T? { note(why); return nil }

    /// Visible-text limit (UTF-16 units) for the HTML editor, which rewrites the whole body on every save.
    static let maxEditableLength = 100_000
    /// Visible-text limit for Notes-backed (Accessibility) editing, which only sends minimal text diffs.
    static let maxNotesBackedLength = 200_000
    /// Safety net for the HTML parser: markup (without images) beyond this is not parsed.
    static let maxHTMLParseLength = 2_000_000

    static let textColor = NSColor.white
    static let dimColor = NSColor.white.withAlphaComponent(0.55)
    static let bodySize: CGFloat = Typo.noteBodySize

    // MARK: Display attributes

    static func font(for s: NoteStyle) -> NSFont {
        let base: NSFont
        if s.heading > 0 {
            let size: CGFloat = s.heading == 1 ? Typo.noteH1Size : Typo.noteH2Size
            base = s.mono ? .monospacedSystemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size, weight: .semibold)
        } else if s.mono {
            base = .monospacedSystemFont(ofSize: Typo.noteMonoSize, weight: s.bold ? .bold : .regular)
        } else {
            base = .systemFont(ofSize: bodySize, weight: s.bold ? .bold : .regular)
        }
        guard s.italic else { return base }
        let d = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: d, size: base.pointSize) ?? base
    }

    static let listIndent: CGFloat = 20

    static func paragraphStyle(list: Bool) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = Typo.noteLineSpacing
        if list {
            p.headIndent = listIndent
            p.firstLineHeadIndent = 0
            p.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
            p.defaultTabInterval = listIndent
        }
        return p
    }

    /// Attributes for a new plain run (typing attributes after a reset).
    static var baseAttributes: [NSAttributedString.Key: Any] {
        var a = NoteStyle().attributes
        a[.paragraphStyle] = paragraphStyle(list: false)
        return a
    }

    static func markerString(_ kind: String, number: Int) -> NSAttributedString {
        NSAttributedString(string: kind == "ol" ? "\(number).\t" : kind == "dl" ? "\u{2013}\t" : "\u{2022}\t", attributes: [
            .nMarker: kind, .font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: dimColor,
            .paragraphStyle: paragraphStyle(list: true)])
    }

    // MARK: Parsing

    struct ParsedPara {
        var list: String?
        var runs: [(String, NoteStyle)]
    }

    private enum Tok {
        case text(String)
        case open(String, [(String, String)])
        case close(String)
    }

    /// Decodes the entities Notes emits (the semicolon is optional) plus numeric references. An unknown `&`
    /// stays literal; the plaintext comparison in `makeEditable` catches any resulting difference.
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        let table: [(String, String)] = [("amp", "&"), ("lt", "<"), ("gt", ">"), ("quot", "\""), ("apos", "'"), ("nbsp", "\u{A0}")]
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c != "&" { out.append(c); i = s.index(after: i); continue }
            let after = s.index(after: i)
            if after < s.endIndex, s[after] == "#" {
                var j = s.index(after: after)
                var hex = false
                if j < s.endIndex, s[j] == "x" || s[j] == "X" { hex = true; j = s.index(after: j) }
                let digitsStart = j
                while j < s.endIndex, s[j].isHexDigit, hex || s[j].isNumber { j = s.index(after: j) }
                if j > digitsStart, let v = UInt32(s[digitsStart..<j], radix: hex ? 16 : 10), let u = Unicode.Scalar(v) {
                    out.unicodeScalars.append(u)
                    i = (j < s.endIndex && s[j] == ";") ? s.index(after: j) : j
                    continue
                }
            }
            if let hit = table.first(where: { s[after...].hasPrefix($0.0) }) {
                out += hit.1
                i = s.index(after, offsetBy: hit.0.count)
                if i < s.endIndex, s[i] == ";" { i = s.index(after: i) }
            } else {
                out.append("&")
                i = after
            }
        }
        return out
    }

    private static func tokenize(_ html: String) -> [Tok]? {
        let u = Array(html.unicodeScalars)
        var toks: [Tok] = []
        var i = 0
        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\n" || c == "\t" || c == "\r" }
        func isNameChar(_ c: Unicode.Scalar) -> Bool { (c.value < 128) && (c.properties.isAlphabetic || (c.value >= 48 && c.value <= 57)) }
        while i < u.count {
            if u[i] != "<" {
                var j = i
                while j < u.count, u[j] != "<" { j += 1 }
                var s = String.UnicodeScalarView(); s.append(contentsOf: u[i..<j])
                toks.append(.text(decode(String(s))))
                i = j
                continue
            }
            i += 1
            guard i < u.count else { return nil }
            if u[i] == "!" || u[i] == "?" { return nil }
            if u[i] == "/" {
                i += 1
                var name = ""
                while i < u.count, isNameChar(u[i]) { name.unicodeScalars.append(u[i]); i += 1 }
                while i < u.count, isSpace(u[i]) { i += 1 }
                guard i < u.count, u[i] == ">", !name.isEmpty else { return nil }
                i += 1
                toks.append(.close(name.lowercased()))
                continue
            }
            var name = ""
            while i < u.count, isNameChar(u[i]) { name.unicodeScalars.append(u[i]); i += 1 }
            guard !name.isEmpty else { return nil }
            var attrs: [(String, String)] = []
            var selfClosing = false
            while true {
                while i < u.count, isSpace(u[i]) { i += 1 }
                guard i < u.count else { return nil }
                if u[i] == ">" { i += 1; break }
                if u[i] == "/" {
                    i += 1
                    guard i < u.count, u[i] == ">" else { return nil }
                    i += 1; selfClosing = true; break
                }
                var an = ""
                while i < u.count, !isSpace(u[i]), u[i] != "=", u[i] != ">", u[i] != "/" { an.unicodeScalars.append(u[i]); i += 1 }
                guard !an.isEmpty else { return nil }
                var av = ""
                while i < u.count, isSpace(u[i]) { i += 1 }
                if i < u.count, u[i] == "=" {
                    i += 1
                    while i < u.count, isSpace(u[i]) { i += 1 }
                    guard i < u.count else { return nil }
                    if u[i] == "\"" || u[i] == "'" {
                        let q = u[i]; i += 1
                        while i < u.count, u[i] != q { av.unicodeScalars.append(u[i]); i += 1 }
                        guard i < u.count else { return nil }
                        i += 1
                    } else {
                        while i < u.count, !isSpace(u[i]), u[i] != ">" { av.unicodeScalars.append(u[i]); i += 1 }
                    }
                }
                attrs.append((an.lowercased(), decode(av)))
            }
            let lname = name.lowercased()
            if selfClosing, lname != "br" { return nil }
            toks.append(.open(lname, attrs))
        }
        return toks
    }

    private static func applyFace(_ face: String, to s: inout NoteStyle) -> Bool {
        let f = face.lowercased()
        if f.hasPrefix(".applesystemuifont") {
            switch f.dropFirst(".applesystemuifont".count) {
            case "": return true
            case "bold": s.bold = true; return true
            case "italic": s.italic = true; return true
            case "bolditalic": s.bold = true; s.italic = true; return true
            default: return false
            }
        }
        if f == "courier" || f == "courier new" || f == "menlo" || f == "monaco" || f == "sf mono" { s.mono = true; return true }
        return false
    }

    private static func applyDeclarations(_ css: String, to s: inout NoteStyle) -> Bool {
        for decl in css.split(separator: ";") {
            let parts = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2 else { return false }
            let v = parts[1]
            switch parts[0] {
            case "font-size":
                guard v.hasSuffix("px"), let n = Int(v.dropLast(2)) else { return false }
                switch n {
                case 24: s.heading = 1
                case 18: s.heading = 2
                case 13: break
                default: return false
                }
            case "font-weight":
                guard ["bold", "600", "700", "800", "900"].contains(v) else { return false }
                s.bold = true
            case "font-style":
                guard v == "italic" else { return false }
                s.italic = true
            case "text-decoration":
                for t in v.split(separator: " ") {
                    switch t {
                    case "underline": s.underline = true
                    case "line-through": s.strike = true
                    default: return false
                    }
                }
            default: return false
            }
        }
        return true
    }

    /// Parses inline content up to the matching `</closeName>`; `i` ends just after it.
    private static func parseInline(_ toks: [Tok], _ i: inout Int, closeName: String) -> ParsedPara? {
        var runs: [(String, NoteStyle)] = []
        var stack: [(String, NoteStyle)] = []
        var style = NoteStyle()
        var sawBr = false
        while i < toks.count {
            let t = toks[i]; i += 1
            switch t {
            case .text(let s):
                if s.contains(where: { "\n\r\u{2028}\u{2029}".contains($0) }) { return bad("line/paragraph separator inside a text node") }
                if !s.isEmpty { runs.append((s, style)) }
            case .close(let n):
                if let top = stack.last {
                    guard top.0 == n else { return bad("mismatched </\(n)>") }
                    style = top.1; stack.removeLast()
                } else {
                    guard n == closeName else { return bad("unexpected </\(n)> inside <\(closeName)>") }
                    if runs.isEmpty && !sawBr { return bad("empty <\(closeName)>") }
                    return ParsedPara(list: nil, runs: runs)
                }
            case .open(let n, let attrs):
                if n == "br" {
                    // Only a trailing <br> (Notes adds one after styled runs, or alone for an empty line).
                    let need = stack.count + 1
                    guard attrs.isEmpty, i + need <= toks.count else { return bad("<br> with attributes") }
                    for k in i..<(i + need) { guard case .close = toks[k] else { return bad("<br> in the middle of a line (soft break)") } }
                    sawBr = true
                    continue
                }
                var ns = style
                switch n {
                case "b", "strong": guard attrs.isEmpty else { return nil }; ns.bold = true
                case "i", "em": guard attrs.isEmpty else { return nil }; ns.italic = true
                case "u": guard attrs.isEmpty else { return nil }; ns.underline = true
                case "strike", "s": guard attrs.isEmpty else { return nil }; ns.strike = true
                case "tt": guard attrs.isEmpty else { return nil }; ns.mono = true
                case "a":
                    guard attrs.count == 1, attrs[0].0 == "href" else { return bad("<a> attributes \(attrs.map { $0.0 })") }
                    ns.link = attrs[0].1
                case "font":
                    for (k, v) in attrs { guard k == "face", applyFace(v, to: &ns) else { return bad("<font \(k)=\(k == "face" ? v : "…")>") } }
                case "span":
                    for (k, v) in attrs { guard k == "style", applyDeclarations(v, to: &ns) else { return bad("<span \(k)> declarations: \(k == "style" ? declNames(v) : "…")") } }
                default: return bad("disallowed inline tag <\(n)>")
                }
                stack.append((n, style)); style = ns
            }
        }
        return bad("unclosed <\(closeName)>")
    }

    private static func declNames(_ css: String) -> String {
        css.split(separator: ";").map { $0.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?" }.joined(separator: ",")
    }

    /// `dir="auto|ltr"` carries no formatting Notes would lose; any other attribute is left in place.
    private static func stripDir(_ attrs: [(String, String)]) -> [(String, String)] {
        attrs.filter { !($0.0 == "dir" && ["auto", "ltr"].contains($0.1.lowercased())) }
    }

    private static func attrNames(_ attrs: [(String, String)]) -> String { attrs.map { $0.0 }.joined(separator: ",") }

    /// List kind for a `<ul>`/`<ol>` open tag: "ul", "ol", or "dl" (Notes' dashed list, `class="Apple-dash-list"`).
    private static func listKind(_ name: String, _ attrs: [(String, String)]) -> String? {
        if attrs.isEmpty { return name }
        if name == "ul", attrs.count == 1, attrs[0].0 == "class", attrs[0].1 == "Apple-dash-list" { return "dl" }
        return bad("<\(name)> attributes \(attrNames(attrs))\(attrs.first(where: { $0.0 == "class" }).map { " class=\($0.1)" } ?? "")")
    }

    static func parseParagraphs(_ html: String) -> [ParsedPara]? {
        guard let toks = tokenize(html) else { return bad("malformed HTML (tokenizer: comment, bad tag or attribute syntax)") }
        var i = 0
        var paras: [ParsedPara] = []
        while i < toks.count {
            switch toks[i] {
            case .text(let t):
                guard t.allSatisfy(\.isWhitespace) else { return bad("text outside any block element") }
                i += 1
            case .close(let c): return bad("stray </\(c)>")
            case .open(let name, let rawAttrs):
                i += 1
                let attrs = stripDir(rawAttrs)
                switch name {
                case "div", "p":
                    guard attrs.isEmpty else { return bad("<\(name)> attributes \(attrNames(attrs))") }
                    guard let p = parseInline(toks, &i, closeName: name) else { return nil }
                    paras.append(p)
                case "h1", "h2", "h3":
                    guard attrs.isEmpty else { return bad("<\(name)> attributes \(attrNames(attrs))") }
                    guard var p = parseInline(toks, &i, closeName: name) else { return nil }
                    p.runs = p.runs.map { r in
                        var s = r.1
                        s.bold = true
                        if name == "h1" { s.heading = 1 } else if name == "h2" { s.heading = 2 }
                        return (r.0, s)
                    }
                    paras.append(p)
                case "ul", "ol":
                    guard let kind = listKind(name, attrs) else { return nil }
                    var closed = false
                    while i < toks.count, !closed {
                        switch toks[i] {
                        case .text(let t):
                            guard t.allSatisfy(\.isWhitespace) else { return bad("text directly inside <\(name)>") }
                            i += 1
                        case .close(let c):
                            guard c == name else { return bad("unexpected </\(c)> inside <\(name)>") }
                            i += 1; closed = true
                        case .open(let n, let a):
                            guard n == "li" else { return bad("<\(n)> directly inside <\(name)> (nested list?)") }
                            guard stripDir(a).isEmpty else { return bad("<li> attributes \(attrNames(a))") }
                            i += 1
                            // Notes sometimes wraps the item text in a single <div>.
                            var wrapped = false
                            var j = i
                            while j < toks.count, case .text(let t) = toks[j], t.allSatisfy(\.isWhitespace) { j += 1 }
                            if j < toks.count, case .open("div", let da) = toks[j], stripDir(da).isEmpty { wrapped = true; i = j + 1 }
                            guard var p = parseInline(toks, &i, closeName: wrapped ? "div" : "li") else { return nil }
                            if wrapped {
                                while i < toks.count, case .text(let t) = toks[i], t.allSatisfy(\.isWhitespace) { i += 1 }
                                guard i < toks.count, case .close("li") = toks[i] else { return bad("content after <div> inside <li>") }
                                i += 1
                            }
                            p.list = kind
                            paras.append(p)
                        }
                    }
                    guard closed else { return bad("unclosed <\(name)>") }
                default: return bad("disallowed block tag <\(name)>")
                }
            }
        }
        if paras.isEmpty { paras = [ParsedPara(list: nil, runs: [])] }
        // A heading must be bold in the source (the model treats headings as bold).
        for p in paras { for r in p.runs where r.1.heading > 0 && !r.1.bold { return bad("heading run that is not bold") } }
        return paras
    }

    // MARK: Attributed string

    static func attributed(from paras: [ParsedPara]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (i, p) in paras.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
            if let k = p.list { out.append(markerString(k, number: 1)) }
            for (t, st) in p.runs { out.append(NSAttributedString(string: t, attributes: st.attributes)) }
        }
        _ = normalizeMarkers(out, selection: NSRange(location: 0, length: 0))
        return out
    }

    /// Kind ("ul"/"ol") and length of the marker at the start of a paragraph.
    static func markerInfo(_ a: NSAttributedString, paraStart: Int, paraEnd: Int) -> (kind: String?, length: Int) {
        guard paraEnd > paraStart else { return (nil, 0) }
        var r = NSRange()
        guard let k = a.attribute(.nMarker, at: paraStart, longestEffectiveRange: &r,
                                  in: NSRange(location: paraStart, length: paraEnd - paraStart)) as? String else { return (nil, 0) }
        return (k, r.length)
    }

    /// Makes every list paragraph start with exactly its correct marker ("•\t", or "N.\t" counted per run of
    /// numbered items), removes stray marker characters and applies paragraph styles. Returns the adjusted selection.
    @discardableResult
    static func normalizeMarkers(_ s: NSMutableAttributedString, selection: NSRange) -> NSRange {
        var sel = selection
        var start = 0
        var counter = 0
        var prevKind: String?
        var editing = false
        func begin() { if !editing { s.beginEditing(); editing = true } }
        while true {
            var ns = s.string as NSString
            let nl = start <= ns.length ? ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start)).location : NSNotFound
            var end = nl == NSNotFound ? ns.length : nl
            var (kind, ml) = markerInfo(s, paraStart: start, paraEnd: end)
            if let k = kind {
                counter = prevKind == k ? counter + 1 : 1
                let expected = markerString(k, number: counter)
                if ml != expected.length || ns.substring(with: NSRange(location: start, length: ml)) != expected.string {
                    begin()
                    s.replaceCharacters(in: NSRange(location: start, length: ml), with: expected)
                    let delta = expected.length - ml
                    if sel.location >= start + ml { sel.location += delta }
                    else if sel.location > start { sel.location = start + expected.length }
                    end += delta; ml = expected.length
                    ns = s.string as NSString
                }
                prevKind = k
            } else { prevKind = nil; counter = 0; kind = nil }
            // Stray marker characters after the prefix are removed.
            if end > start + ml {
                var strays: [NSRange] = []
                s.enumerateAttribute(.nMarker, in: NSRange(location: start + ml, length: end - start - ml)) { v, r, _ in
                    if v != nil { strays.append(r) }
                }
                for r in strays.reversed() {
                    begin()
                    s.deleteCharacters(in: r)
                    if sel.location > r.location { sel.location = max(r.location, sel.location - r.length) }
                    end -= r.length
                }
            }
            ns = s.string as NSString
            let pr = NSRange(location: start, length: min(ns.length - start, end - start + (nl == NSNotFound ? 0 : 1)))
            if pr.length > 0 {
                let want = paragraphStyle(list: kind != nil)
                if let have = s.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle, have.isEqual(want) {
                    // already right
                } else {
                    begin()
                    s.addAttribute(.paragraphStyle, value: want, range: pr)
                }
            }
            if nl == NSNotFound { break }
            start = end + 1
        }
        if editing { s.endEditing() }
        return NSRange(location: min(sel.location, s.length), length: min(sel.length, max(0, s.length - sel.location)))
    }

    /// Re-derives font and color from the semantic attributes over whole paragraphs touching `range`.
    static func restyle(_ s: NSMutableAttributedString, range: NSRange) {
        guard s.length > 0 else { return }
        let r0 = NSRange(location: min(range.location, s.length), length: min(range.length, s.length - min(range.location, s.length)))
        let full = (s.string as NSString).paragraphRange(for: r0)
        var jobs: [(NSRange, [NSAttributedString.Key: Any], [NSAttributedString.Key])] = []
        s.enumerateAttributes(in: full) { attrs, r, _ in
            if attrs[.nMarker] != nil {
                jobs.append((r, [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: dimColor], [.nBold, .nItalic, .nMono, .nHeading]))
                return
            }
            let want = NoteStyle(attrs: attrs).attributes
            let stale = [NSAttributedString.Key.nBold, .nItalic, .nMono, .nHeading].filter { want[$0] == nil && attrs[$0] != nil }
            jobs.append((r, want, stale))
        }
        s.beginEditing()
        for (r, want, stale) in jobs {
            for k in stale { s.removeAttribute(k, range: r) }
            s.addAttributes(want, range: r)
        }
        s.endEditing()
        normalizeMarkers(s, selection: NSRange(location: 0, length: 0))
    }

    // MARK: Formatting operations (used by the text view's shortcuts)

    enum Format { case bold, italic, underline, strike }

    static func isOn(_ f: Format, _ st: NoteStyle) -> Bool {
        switch f {
        case .bold: return st.bold || st.heading > 0
        case .italic: return st.italic
        case .underline: return st.underline
        case .strike: return st.strike
        }
    }

    static func set(_ f: Format, _ on: Bool, in st: NoteStyle) -> NoteStyle {
        var s = st
        switch f {
        case .bold: s.bold = on; if !on { s.heading = 0 }
        case .italic: s.italic = on
        case .underline: s.underline = on
        case .strike: s.strike = on
        }
        return s
    }

    /// Toggles a format over `range` (ignoring list markers). Returns the new state, or nil if nothing changed.
    @discardableResult
    static func toggle(_ f: Format, in s: NSMutableAttributedString, range: NSRange) -> Bool? {
        guard range.length > 0, NSMaxRange(range) <= s.length else { return nil }
        var all = true, any = false
        s.enumerateAttributes(in: range) { attrs, _, _ in
            if attrs[.nMarker] != nil { return }
            any = true
            if !isOn(f, NoteStyle(attrs: attrs)) { all = false }
        }
        guard any else { return nil }
        let on = !all
        var jobs: [(NSRange, NoteStyle)] = []
        s.enumerateAttributes(in: range) { attrs, r, _ in
            if attrs[.nMarker] != nil { return }
            jobs.append((r, set(f, on, in: NoteStyle(attrs: attrs))))
        }
        s.beginEditing()
        for (r, st) in jobs {
            for k in [NSAttributedString.Key.nBold, .nItalic, .nMono, .nHeading, .underlineStyle, .strikethroughStyle] { s.removeAttribute(k, range: r) }
            s.addAttributes(st.attributes, range: r)
        }
        s.endEditing()
        return on
    }

    /// Keeps only bold / italic / underline / strike / monospace / links from pasted rich text.
    static func sanitize(_ pasted: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        pasted.enumerateAttributes(in: NSRange(location: 0, length: pasted.length)) { attrs, r, _ in
            var st = NoteStyle()
            if let f = attrs[.font] as? NSFont {
                let t = f.fontDescriptor.symbolicTraits
                st.bold = t.contains(.bold); st.italic = t.contains(.italic)
                st.mono = t.contains(.monoSpace) || f.isFixedPitch
            }
            st.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
            st.strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
            if let s = attrs[.link] as? String { st.link = s } else if let u = attrs[.link] as? URL { st.link = u.absoluteString }
            var text = pasted.attributedSubstring(from: r).string
            text = cleanText(text)
            if !text.isEmpty { out.append(NSAttributedString(string: text, attributes: st.attributes)) }
        }
        return out
    }

    /// Single line-feed line endings, no attachment characters.
    static func cleanText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    // MARK: Serializing

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ s: String) -> String { escape(s).replacingOccurrences(of: "\"", with: "&quot;") }

    private static func wrappers(_ st: NoteStyle) -> (open: String, close: String) {
        var o = "", c = ""
        func add(_ a: String, _ b: String) { o += a; c = b + c }
        if st.heading > 0 {
            add("<b><font face=\".AppleSystemUIFontBold\"><span style=\"font-size: \(st.heading == 1 ? 24 : 18)px\">", "</span></font></b>")
        } else if st.bold { add("<b>", "</b>") }
        if st.italic { add("<i>", "</i>") }
        if st.underline { add("<u>", "</u>") }
        if st.strike { add("<strike>", "</strike>") }
        if st.mono { add("<tt>", "</tt>") }
        if let l = st.link { add("<a href=\"\(escapeAttr(l))\">", "</a>") }
        return (o, c)
    }

    /// Notes-compatible minimal HTML. Default text color and font are never written.
    static func serialize(_ a: NSAttributedString) -> String {
        let ns = a.string as NSString
        var out = ""
        var openList: String?
        var start = 0
        while true {
            let nl = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start)).location
            let end = nl == NSNotFound ? ns.length : nl
            let (kind, ml) = markerInfo(a, paraStart: start, paraEnd: end)
            let cs = start + ml
            var body = ""
            if end > cs {
                a.enumerateAttributes(in: NSRange(location: cs, length: end - cs)) { attrs, r, _ in
                    let st = NoteStyle(attrs: attrs)
                    var units: [UInt16] = []
                    for idx in r.location..<NSMaxRange(r) {
                        let u = ns.character(at: idx)
                        switch u {
                        case 0x26: units += Array("&amp;".utf16)
                        case 0x3C: units += Array("&lt;".utf16)
                        case 0x3E: units += Array("&gt;".utf16)
                        case 0xFFFC: break
                        case 0x20:
                            let lead = idx == cs, trail = idx == end - 1
                            let prevSp = idx > cs && ns.character(at: idx - 1) == 0x20
                            let nextSp = idx + 1 < end && ns.character(at: idx + 1) == 0x20
                            units += (lead || trail || prevSp || nextSp) ? Array("&nbsp;".utf16) : [u]
                        default: units.append(u)
                        }
                    }
                    guard !units.isEmpty else { return }
                    let w = wrappers(st)
                    body += w.open + String(decoding: units, as: UTF16.self) + w.close
                }
            }
            if let k = kind {
                if openList != k {
                    if let o = openList { out += o == "ol" ? "</ol>" : "</ul>" }
                    out += k == "ol" ? "<ol>" : k == "dl" ? "<ul class=\"Apple-dash-list\">" : "<ul>"; openList = k
                }
                out += "<li>\(body.isEmpty ? "<br>" : body)</li>"
            } else {
                if let o = openList { out += o == "ol" ? "</ol>" : "</ul>"; openList = nil }
                out += "<div>\(body.isEmpty ? "<br>" : body)</div>"
            }
            if nl == NSNotFound { break }
            start = nl + 1
        }
        if let o = openList { out += o == "ol" ? "</ol>" : "</ul>" }
        return out
    }

    // MARK: Safety checks

    /// Text and formatting only (display attributes ignored), for the round-trip comparison.
    static func dump(_ a: NSAttributedString) -> [String] {
        let ns = a.string as NSString
        var out: [String] = []
        var start = 0
        while true {
            let nl = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start)).location
            let end = nl == NSNotFound ? ns.length : nl
            let (kind, ml) = markerInfo(a, paraStart: start, paraEnd: end)
            var runs: [(String, String)] = []
            if end > start + ml {
                a.enumerateAttributes(in: NSRange(location: start + ml, length: end - start - ml)) { attrs, r, _ in
                    let sig = NoteStyle(attrs: attrs).signature
                    let text = cleanText(ns.substring(with: r)).replacingOccurrences(of: "\u{A0}", with: " ")
                    if let last = runs.last, last.0 == sig { runs[runs.count - 1].1 += text } else { runs.append((sig, text)) }
                }
            }
            out.append((kind ?? "-") + runs.map { "[\($0.0)]\($0.1)" }.joined())
            if nl == NSNotFound { break }
            start = nl + 1
        }
        return out
    }

    /// Plain text of the editor content (list markers excluded), lines joined by "\n".
    static func plainText(_ a: NSAttributedString) -> String {
        let ns = a.string as NSString
        var lines: [String] = []
        var start = 0
        while true {
            let nl = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start)).location
            let end = nl == NSNotFound ? ns.length : nl
            let (_, ml) = markerInfo(a, paraStart: start, paraEnd: end)
            lines.append(ns.substring(with: NSRange(location: start + ml, length: end - start - ml)))
            if nl == NSNotFound { break }
            start = nl + 1
        }
        return lines.joined(separator: "\n")
    }

    /// Notes' `plaintext` vs the text we decoded. Notes may add a trailing newline, a U+2028 for a trailing `<br>`
    /// in an item, and (depending on version) list markers or stray spaces; none of those are note content.
    static func plaintextMatches(_ decoded: String, _ notesPlain: String) -> Bool {
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }
        var ours = norm(decoded).components(separatedBy: "\n")
        var theirs = norm(notesPlain).components(separatedBy: "\n")
        func clean(_ l: String) -> String {
            var l = l
            while let c = l.last, c == "\u{2028}" || c == "\u{2029}" { l.removeLast() }
            return l
        }
        theirs = theirs.map(clean)
        while theirs.count > ours.count, theirs.last == "" { theirs.removeLast() }
        while ours.count > theirs.count, ours.last == "" { ours.removeLast() }
        guard ours.count == theirs.count else { return false }
        for (o, t) in zip(ours, theirs) where o != t {
            let tt = t.trimmingCharacters(in: .whitespaces), oo = o.trimmingCharacters(in: .whitespaces)
            if tt == oo { continue }
            let stripped = tt.replacingOccurrences(of: "^([\\x{2022}\\x{25E6}\\x{25AA}\\x{2013}\\x{2014}-]|[0-9]+\\.)[\\t ]+", with: "",
                                                  options: .regularExpression)
            if stripped != oo { return false }
        }
        return true
    }

    /// The editable attributed text for a note, or nil when editing would not be provably lossless.
    /// `NoteHTML.lastFailure` names the check that failed.
    static func makeEditable(html: String, plaintext: String) -> NSAttributedString? {
        guard html.utf16.count <= maxHTMLParseLength else { return bad("allowlist: html too large to parse") }
        guard let paras = parseParagraphs(html) else { return nil }
        let a = attributed(from: paras)
        guard plaintextMatches(plainText(a), plaintext) else {
            return bad("plaintext-mismatch: \(structureDiff(plainText(a), plaintext))")
        }
        // Round trip: what we would write back must read as exactly the same note.
        guard let again = parseParagraphs(serialize(a)) else { return bad("round-trip: our own HTML does not re-parse (\(lastFailure))") }
        let d1 = dump(a), d2 = dump(attributed(from: again))
        guard d1 == d2 else { return bad("round-trip-mismatch: \(d1.count) vs \(d2.count) paragraphs; first diff \(zip(d1, d2).enumerated().first { $0.element.0 != $0.element.1 }.map { "#\($0.offset)" } ?? "length")") }
        return a
    }

    /// Text-free structure of a string: per line, letter->x, digit->9, other chars kept only if non-alphanumeric.
    static func structureDiff(_ ours: String, _ theirs: String) -> String {
        func sk(_ s: String) -> String {
            s.unicodeScalars.map { c -> String in
                if c == "\n" { return "\\n" }
                if CharacterSet.letters.contains(c) { return "x" }
                if CharacterSet.decimalDigits.contains(c) { return "9" }
                if c == " " { return "_" }
                return String(format: "U+%04X", c.value)
            }.joined()
        }
        return "ours=[\(sk(ours))] notes=[\(sk(theirs))]"
    }

    /// Replaces every embedded object / image (whose base64 payload can be megabytes) with one U+FFFC.
    static func stripImages(_ html: String) -> String {
        guard html.range(of: "<img", options: .caseInsensitive) != nil || html.range(of: "<object", options: .caseInsensitive) != nil else { return html }
        return html
            .replacingOccurrences(of: "(?s)<object\\b.*?</object>", with: "\u{FFFC}", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<img\\b[^>]*>", with: "\u{FFFC}", options: [.regularExpression, .caseInsensitive])
    }

    /// Best-effort text with list markers for the read-only view; nil when the HTML is not understood at all.
    static func readOnlyDisplay(html: String) -> String? {
        let h = stripImages(html)
        guard h.utf16.count <= maxHTMLParseLength, let paras = parseParagraphs(h) else { return nil }
        return attributed(from: paras).string
    }

    /// First non-empty line of the content, for the header title.
    static func title(of a: NSAttributedString) -> String? {
        plainText(a).components(separatedBy: "\n").first.flatMap { $0.isEmpty ? nil : $0 }
    }
}
