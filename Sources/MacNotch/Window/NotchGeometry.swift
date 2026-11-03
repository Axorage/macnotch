import AppKit

/// Geometry of the notch and the (fixed-size) panel that hosts the island.
struct NotchGeometry: Equatable {
    /// Collapsed island size == physical notch size (points).
    var notchSize: CGSize
    /// Max expanded island size (points).
    var expandedSize: CGSize
    /// Panel frame in global screen coordinates (sized once, anchored top-center).
    var panelFrame: CGRect
    var hasPhysicalNotch: Bool

    static var simulatedNotch: CGSize { CGSize(width: 200, height: NSStatusBar.system.thickness) }
    /// Expanded island size (fixed).
    static let maxExpanded = CGSize(width: 680, height: 210)
    static let defaultExpanded = CGSize(width: 680, height: 210)
    /// Extra hover/click slop below the hardware notch while hidden.
    static let hoverSlopBelow: CGFloat = 4
    static let expandedEar: CGFloat = 14
    /// Expanded-state shadow (shared with IslandView): blur radius and y offset.
    static let shadowRadius: CGFloat = 10
    static let shadowOffsetY: CGFloat = 4
    /// Extra room around the island: must contain the shadow (radius + offset, with
    /// 1.5x blur falloff headroom) plus spring overshoot (~6%). Never clip the shadow.
    static let margin: CGFloat = 32

    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    static func compute(for screen: NSScreen, expanded: CGSize = defaultExpanded) -> NotchGeometry {
        var size = simulatedNotch
        var physical = false
        if screen.safeAreaInsets.top > 0 {
            physical = true
            let h = screen.safeAreaInsets.top
            var w = simulatedNotch.width
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                w = max(0, r.minX - l.maxX)
            }
            let k = screen.backingScaleFactor
            size = CGSize(width: (w * k).rounded() / k, height: (h * k).rounded() / k)
        }
        let panelW = maxExpanded.width + expandedEar * 2 + margin * 2
        let panelH = maxExpanded.height + margin
        let f = screen.frame
        let frame = CGRect(x: f.midX - panelW / 2, y: f.maxY - panelH, width: panelW, height: panelH)
        return NotchGeometry(notchSize: size, expandedSize: expanded, panelFrame: frame, hasPhysicalNotch: physical)
    }

    /// Layout used when no screen is attached; the panel stays hidden until
    /// didChangeScreenParameters delivers a real screen.
    static func placeholder() -> NotchGeometry {
        let panelW = maxExpanded.width + expandedEar * 2 + margin * 2
        let panelH = maxExpanded.height + margin
        return NotchGeometry(notchSize: simulatedNotch, expandedSize: defaultExpanded,
                             panelFrame: CGRect(x: 0, y: 0, width: panelW, height: panelH),
                             hasPhysicalNotch: false)
    }

    /// Island rect in panel-local coordinates (origin bottom-left, AppKit), for a given island size.
    func islandRect(size: CGSize, panelHeight: CGFloat? = nil) -> CGRect {
        let ph = panelHeight ?? panelFrame.height
        return CGRect(x: (panelFrame.width - size.width) / 2, y: ph - size.height, width: size.width, height: size.height)
    }
}
