import SwiftUI

/// One continuous island silhouette: flat top, small concave "ears" at the top corners, rounded bottom corners.
/// The shape draws itself top-centred inside whatever rect it is given and animates width, height and both
/// radii together (`animatableData`), so SwiftUI morphs a single path instead of swapping views or frames.
struct NotchShape: InsettableShape {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0
    /// Fill bleeds this far above the rect's top edge (off-screen) so no antialiased/seam row can show at y=0.
    var topBleed: CGFloat = 0
    /// Leave the top edge unstroked (keyline: sides + ears + bottom only; the island merges into the bezel).
    var openTop = false

    func inset(by amount: CGFloat) -> NotchShape {
        var s = self; s.insetAmount += amount; return s
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(width, height), .init(topRadius, bottomRadius)) }
        set {
            width = newValue.first.first; height = newValue.first.second
            topRadius = newValue.second.first; bottomRadius = newValue.second.second
        }
    }

    func path(in full: CGRect) -> Path {
        let w = max(0, width), h = max(0, height)
        // Inset only the sides/bottom: the top edge must stay exactly at full.minY (screen top).
        var rect = CGRect(x: full.midX - w / 2, y: full.minY, width: w, height: h)
            .insetBy(dx: insetAmount, dy: 0)
        rect.size.height -= insetAmount
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let t = max(0, min(topRadius, rect.width / 2, rect.height / 2))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left ear: concave curve from top-left going down/in.
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        if openTop { return p }
        if topBleed > 0 {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY - topBleed))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY - topBleed))
        }
        p.closeSubpath()
        return p
    }
}
