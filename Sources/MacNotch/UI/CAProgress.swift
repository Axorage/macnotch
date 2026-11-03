import SwiftUI
import AppKit

/// Progress drawn by Core Animation. While running, a single linear animation
/// from the current progress to 1 is added; the app does no per-frame or per-second work.
struct CAProgress: NSViewRepresentable {
    enum Style { case ring(diameter: CGFloat, line: CGFloat), bar(height: CGFloat) }
    let style: Style
    let color: NSColor
    let trackColor: NSColor
    let progress: Double
    let remaining: TimeInterval
    let running: Bool
    let key: AnyHashable

    func makeNSView(context: Context) -> ProgressLayerView { ProgressLayerView(style: style) }

    func updateNSView(_ v: ProgressLayerView, context: Context) {
        v.apply(color: color, track: trackColor, progress: progress, remaining: remaining, running: running, key: key)
    }
}

final class ProgressLayerView: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let style: CAProgress.Style
    private var lastKey: AnyHashable?
    private var lastRunning = false
    private var pending: (Double, TimeInterval, Bool)?

    init(style: CAProgress.Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        for l in [track, fill] {
            l.fillColor = nil
            l.lineCap = .round
        }
        fill.strokeEnd = 0
        switch style {
        case .ring(_, let line):
            track.lineWidth = line; fill.lineWidth = line
        case .bar(let h):
            track.lineWidth = h; fill.lineWidth = h
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        switch style {
        case .ring(let d, _): return NSSize(width: d, height: d)
        case .bar(let h): return NSSize(width: NSView.noIntrinsicMetric, height: h)
        }
    }

    override func layout() {
        super.layout()
        let path = CGMutablePath()
        switch style {
        case .ring(_, let line):
            let r = (min(bounds.width, bounds.height) - line) / 2
            // Start at 12 o'clock, clockwise (layer space is y-up).
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: r,
                        startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        case .bar(let h):
            path.move(to: CGPoint(x: h / 2, y: bounds.midY))
            path.addLine(to: CGPoint(x: bounds.width - h / 2, y: bounds.midY))
        }
        track.frame = bounds; fill.frame = bounds
        track.path = path; fill.path = path
        if let p = pending { pending = nil; start(p.0, p.1, p.2) }
    }

    func apply(color: NSColor, track t: NSColor, progress: Double, remaining: TimeInterval, running: Bool, key: AnyHashable) {
        fill.strokeColor = color.cgColor
        track.strokeColor = t.cgColor
        guard key != lastKey || running != lastRunning else { return }
        lastKey = key; lastRunning = running
        if bounds.isEmpty { pending = (progress, remaining, running) } else { start(progress, remaining, running) }
    }

    private func start(_ progress: Double, _ remaining: TimeInterval, _ running: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.removeAllAnimations()
        fill.strokeEnd = running ? 1 : CGFloat(progress)
        CATransaction.commit()
        if running, remaining > 0 {
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = progress
            a.toValue = 1
            a.duration = remaining
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            fill.add(a, forKey: "progress")
        }
    }
}
