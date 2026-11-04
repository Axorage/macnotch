import Foundation

/// One replacement in Notes' text coordinate space (UTF-16, the unit Accessibility uses).
struct TextEdit: Equatable {
    var range: NSRange
    var replacement: String
}

/// Minimal text diff used to apply an edit to Notes through Accessibility.
///
/// Both strings are in Notes' AX coordinate space where every attachment is one U+FFFC. The diff never produces
/// a range that touches a U+FFFC: both texts are split at the placeholders (their count must match), and each
/// piece pair is diffed on its own. Inside a piece the diff is hierarchical (lines, words, then Myers via `CollectionDifference` on composed
/// character sequences), so a surrogate pair or an emoji is never cut in half and separate edits stay separate
/// (replacing one wide range would reset the formatting of every line in between).
enum NotesTextDiff {
    static let placeholder: unichar = 0xFFFC
    /// Above this many cells the exact diff is skipped for one prefix/suffix replace of the piece.
    static let exactLimit = 4_000_000

    /// Edits that turn `base` into `target`, in DESCENDING location order (safe to apply one after another).
    /// nil when the placeholders of the two texts don't line up (an attachment was added or removed).
    static func edits(from base: String, to target: String) -> [TextEdit]? {
        let a = split(base), b = split(target)
        guard a.count == b.count else { return nil }
        var out: [TextEdit] = []
        var offset = 0
        for i in 0..<a.count {
            let (oldPiece, newPiece) = (a[i], b[i])
            out += pieceEdits(oldPiece, newPiece).map {
                TextEdit(range: NSRange(location: offset + $0.range.location, length: $0.range.length), replacement: $0.replacement)
            }
            offset += (oldPiece as NSString).length + 1   // the placeholder that followed the piece
        }
        return out.reversed()
    }

    static func apply(_ e: TextEdit, to s: String) -> String {
        (s as NSString).replacingCharacters(in: e.range, with: e.replacement)
    }

    static func placeholderCount(_ s: String) -> Int { s.utf16.reduce(0) { $0 + ($1 == placeholder ? 1 : 0) } }

    private static func split(_ s: String) -> [String] {
        s.components(separatedBy: "\u{FFFC}")
    }

    private struct Cluster: Equatable {
        let units: [UInt16]
    }

    /// Separators of the coarser diff levels (a token ends AFTER its separator): lines, then words.
    private static let separators: [UInt16] = [10, 32]
    /// Above this many token pairs a level is not diffed exactly.
    private static let tokenLimit = 25_000_000

    /// Ascending, non-overlapping edits inside one piece (locations relative to the piece).
    ///
    /// Hierarchical so that a long text with a few separate edits stays fast and every edit stays small: the
    /// piece is diffed by lines, each changed block of lines by words, each changed block of words by characters.
    private static func pieceEdits(_ old: String, _ new: String) -> [TextEdit] {
        if old.utf16.elementsEqual(new.utf16) { return [] }
        let ctx = Context(a: Array(old.utf16), b: Array(new.utf16), na: old as NSString, nb: new as NSString)
        var out: [TextEdit] = []
        diffRange(ctx, 0..<ctx.a.count, 0..<ctx.b.count, level: 0, into: &out)
        return out
    }

    private struct Context {
        let a: [UInt16], b: [UInt16]
        let na: NSString, nb: NSString
    }

    private static func isBoundary(_ ns: NSString, _ i: Int) -> Bool {
        i <= 0 || i >= ns.length || ns.rangeOfComposedCharacterSequence(at: i).location == i
    }

    private static func replacement(_ ctx: Context, _ ar: Range<Int>, _ br: Range<Int>) -> TextEdit {
        let units = Array(ctx.b[br])
        return TextEdit(range: NSRange(location: ar.lowerBound, length: ar.count),
                        replacement: String(utf16CodeUnits: units, count: units.count))
    }

    private static func diffRange(_ ctx: Context, _ ar0: Range<Int>, _ br0: Range<Int>, level: Int, into out: inout [TextEdit]) {
        var ar = ar0, br = br0
        // Common prefix / suffix, then pulled back to composed-character boundaries of BOTH texts.
        var pre = 0
        while pre < ar.count, pre < br.count, ctx.a[ar.lowerBound + pre] == ctx.b[br.lowerBound + pre] { pre += 1 }
        while pre > 0, !(isBoundary(ctx.na, ar.lowerBound + pre) && isBoundary(ctx.nb, br.lowerBound + pre)) { pre -= 1 }
        ar = (ar.lowerBound + pre)..<ar.upperBound; br = (br.lowerBound + pre)..<br.upperBound
        var suf = 0
        while suf < ar.count, suf < br.count, ctx.a[ar.upperBound - 1 - suf] == ctx.b[br.upperBound - 1 - suf] { suf += 1 }
        while suf > 0, !(isBoundary(ctx.na, ar.upperBound - suf) && isBoundary(ctx.nb, br.upperBound - suf)) { suf -= 1 }
        ar = ar.lowerBound..<(ar.upperBound - suf); br = br.lowerBound..<(br.upperBound - suf)
        if ar.isEmpty && br.isEmpty { return }
        if ar.isEmpty || br.isEmpty { out.append(replacement(ctx, ar, br)); return }

        if ar.count * br.count <= exactLimit || level >= separators.count {
            charEdits(ctx, ar, br, into: &out)
            return
        }
        let ta = tokens(ctx.a, ar, separators[level]), tb = tokens(ctx.b, br, separators[level])
        if ta.count <= 1 && tb.count <= 1 { diffRange(ctx, ar, br, level: level + 1, into: &out); return }

        var ids: [[UInt16]: Int] = [:]
        func id(_ t: Token) -> Int { if let v = ids[t.units] { return v }; let v = ids.count; ids[t.units] = v; return v }
        let ia = ta.map(id), ib = tb.map(id)
        for blk in changedBlocks(ia, ib) {
            let sa = blk.a.lowerBound < ta.count ? ta[blk.a.lowerBound].start : ar.upperBound
            let sb = blk.b.lowerBound < tb.count ? tb[blk.b.lowerBound].start : br.upperBound
            let ea = blk.a.upperBound < ta.count ? ta[blk.a.upperBound].start : ar.upperBound
            let eb = blk.b.upperBound < tb.count ? tb[blk.b.upperBound].start : br.upperBound
            diffRange(ctx, sa..<ea, sb..<eb, level: level + 1, into: &out)
        }
    }

    /// Ascending blocks of tokens that differ. Exact (Myers) while affordable, else a greedy resynchronising walk.
    private static func changedBlocks(_ a: [Int], _ b: [Int]) -> [(a: Range<Int>, b: Range<Int>)] {
        var blocks: [(a: Range<Int>, b: Range<Int>)] = []
        if a.count * b.count <= tokenLimit {
            let diff = b.difference(from: a)
            var removed = Set<Int>(), inserted = Set<Int>()
            for change in diff {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            var i = 0, j = 0
            while i < a.count || j < b.count {
                if (i < a.count && removed.contains(i)) || (j < b.count && inserted.contains(j)) {
                    let (i0, j0) = (i, j)
                    while i < a.count, removed.contains(i) { i += 1 }
                    while j < b.count, inserted.contains(j) { j += 1 }
                    blocks.append((i0..<i, j0..<j))
                } else {
                    guard i < a.count, j < b.count else { break }
                    i += 1; j += 1
                }
            }
            return blocks
        }
        // Greedy: at a mismatch look for the nearest pair of positions where two tokens in a row agree again.
        let window = 64
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            var hit: (Int, Int)?
            search: for d in 1...window {
                for p in 0...d {
                    let q = d - p
                    guard i + p < a.count, j + q < b.count, a[i + p] == b[j + q] else { continue }
                    let more = i + p + 1 >= a.count || j + q + 1 >= b.count || a[i + p + 1] == b[j + q + 1]
                    if more { hit = (p, q); break search }
                }
            }
            guard let (p, q) = hit else { break }
            blocks.append((i..<(i + p), j..<(j + q)))
            i += p; j += q
        }
        if i < a.count || j < b.count { blocks.append((i..<a.count, j..<b.count)) }
        return blocks
    }

    private struct Token { let start: Int; let units: [UInt16] }

    private static func tokens(_ u: [UInt16], _ r: Range<Int>, _ sep: UInt16) -> [Token] {
        var out: [Token] = []
        var s = r.lowerBound
        var k = r.lowerBound
        while k < r.upperBound {
            if u[k] == sep { out.append(Token(start: s, units: Array(u[s...k]))); s = k + 1 }
            k += 1
        }
        if s < r.upperBound { out.append(Token(start: s, units: Array(u[s..<r.upperBound]))) }
        return out
    }

    private static func clusters(_ ns: NSString, _ r: Range<Int>) -> [Cluster] {
        var out: [Cluster] = []
        var i = r.lowerBound
        while i < r.upperBound {
            let c = ns.rangeOfComposedCharacterSequence(at: i)
            let end = min(NSMaxRange(c), r.upperBound)
            out.append(Cluster(units: (i..<end).map { ns.character(at: $0) }))
            i = end
        }
        return out
    }

    /// Character-level diff (Myers via CollectionDifference) of two ranges whose edges are character boundaries.
    private static func charEdits(_ ctx: Context, _ ar: Range<Int>, _ br: Range<Int>, into out: inout [TextEdit]) {
        let ma = clusters(ctx.na, ar), mb = clusters(ctx.nb, br)
        if ma.isEmpty || mb.isEmpty || ma.count * mb.count > exactLimit { out.append(replacement(ctx, ar, br)); return }
        let diff = mb.difference(from: ma)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0, loc = ar.lowerBound
        while i < ma.count || j < mb.count {
            if (i < ma.count && removed.contains(i)) || (j < mb.count && inserted.contains(j)) {
                var delLen = 0, ins: [UInt16] = []
                while i < ma.count, removed.contains(i) { delLen += ma[i].units.count; i += 1 }
                while j < mb.count, inserted.contains(j) { ins += mb[j].units; j += 1 }
                out.append(TextEdit(range: NSRange(location: loc, length: delLen),
                                    replacement: String(utf16CodeUnits: ins, count: ins.count)))
                loc += delLen
            } else {
                guard i < ma.count, j < mb.count else { break }
                loc += ma[i].units.count
                i += 1; j += 1
            }
        }
    }
}
