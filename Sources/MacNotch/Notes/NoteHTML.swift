import Foundation

/// Conversion between the plain text shown in the notch editor and the HTML that Notes stores in `body`.
///
/// Setting `body` replaces the whole note, so this is deliberately conservative: a note is only editable
/// when its HTML is a flat list of `<div>` lines (optionally with a styled first line) AND the text decoded
/// from that HTML is identical to Notes' own `plaintext`. Anything else (lists, checklists, tables, bold or
/// links in the body, attachments, soft line breaks, unknown entities) is treated as rich content.
enum NoteHTML {
    struct Doc: Equatable {
        var lines: [String]
        /// Opening / closing tags that style the first line (Notes' title style), preserved on save.
        var prefix: String
        var suffix: String
        var text: String { lines.joined(separator: "\n") }
    }

    /// Notes longer than this are read-only in the notch (a single Apple Event stays small and fast).
    static let maxEditableLength = 60_000

    private static let titleTags: Set<String> = ["b", "h1", "span", "font"]

    static func parse(html: String, plaintext: String) -> Doc? {
        guard html.count <= maxEditableLength else { return nil }
        var rest = Substring(html)
        var inners: [String] = []
        while true {
            while let c = rest.first, c.isWhitespace { rest = rest.dropFirst() }
            if rest.isEmpty { break }
            guard rest.hasPrefix("<div>"), let close = rest.range(of: "</div>") else { return nil }
            let inner = String(rest[rest.index(rest.startIndex, offsetBy: 5)..<close.lowerBound])
            if inner.contains("<div") { return nil }
            inners.append(inner)
            rest = rest[close.upperBound...]
        }
        var doc = Doc(lines: [], prefix: "", suffix: "")
        for (i, raw) in inners.enumerated() {
            var inner = raw
            if inner == "<br>" { doc.lines.append(""); continue }
            // Notes appends a <br> to lines that end in a styled run; it is not an extra line (the plaintext
            // comparison below still has to match).
            if inner.hasSuffix("<br>") { inner.removeLast(4) }
            if i == 0 {
                var opens: [(String, String)] = []
                while inner.hasPrefix("<") {
                    guard let end = inner.firstIndex(of: ">") else { return nil }
                    let tag = String(inner[inner.startIndex...end])
                    let name = tag.dropFirst().prefix { $0.isLetter || $0.isNumber }.lowercased()
                    let close = "</\(name)>"
                    guard titleTags.contains(name), inner.hasSuffix(close),
                          inner.count >= tag.count + close.count else { return nil }
                    opens.append((tag, close))
                    inner = String(inner[inner.index(after: end)..<inner.index(inner.endIndex, offsetBy: -close.count)])
                }
                doc.prefix = opens.map(\.0).joined()
                doc.suffix = opens.reversed().map(\.1).joined()
            }
            if inner.contains("<") { return nil }
            guard let text = decode(inner) else { return nil }
            doc.lines.append(text)
        }
        if doc.lines.isEmpty { doc.lines = [""] }
        // AppleScript's `plaintext` ends with one extra line feed.
        guard doc.text == plaintext || doc.text + "\n" == plaintext else { return nil }
        return doc
    }

    /// Decodes the entities Notes emits (with or without the trailing semicolon). nil = unknown entity.
    static func decode(_ s: String) -> String? {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        let table: [(String, String)] = [("amp", "&"), ("lt", "<"), ("gt", ">"), ("quot", "\""), ("nbsp", "\u{A0}")]
        while i < s.endIndex {
            let c = s[i]
            if c != "&" { out.append(c); i = s.index(after: i); continue }
            let after = s.index(after: i)
            guard let hit = table.first(where: { s[after...].hasPrefix($0.0) }) else { return nil }
            out += hit.1
            i = s.index(after, offsetBy: hit.0.count)
            // The semicolon is optional in what Notes emits. A literal ";" that follows is caught by the
            // plaintext-equality check in `parse`, which then leaves the note read-only.
            if i < s.endIndex, s[i] == ";" { i = s.index(after: i) }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Editor text (any line endings) to HTML, keeping the original first-line styling.
    static func render(text: String, prefix: String, suffix: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        return lines.enumerated().map { i, line in
            if line.isEmpty { return "<div><br></div>" }
            let e = escape(line)
            return i == 0 ? "<div>\(prefix)\(e)\(suffix)</div>" : "<div>\(e)</div>"
        }.joined()
    }
}
