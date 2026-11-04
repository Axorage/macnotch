import SwiftUI

enum Space {
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
}

enum Metrics {
    static let wing: CGFloat = 52
    static let liveEar: CGFloat = 6
    /// Fits "00:00" at timeCompact (13 pt semibold, monospaced digits) with slack.
    static let compactTimeWidth: CGFloat = 40
    static let expandedEar: CGFloat = 14
    static let hardwareCornerRadius: CGFloat = 9
    static let liveBottom: CGFloat = 12
    static let expandedBottom: CGFloat = 26
    static let rowHeight: CGFloat = 40
    static let rowRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10
    static let minHit: CGFloat = 28
    // Inline expanded layout (docs/DESIGN.md section 2.4)
    /// Inset below the notch band before the panes start.
    static let bandGap: CGFloat = 6
    static let paneBottom: CGFloat = 16
    static let pomodoroPaneWidth: CGFloat = 272
    static let paneGap: CGFloat = 24
    static let timerRing: CGFloat = 112
    static let timerRingLine: CGFloat = 5
    static let primaryButton: CGFloat = 40
    /// Clear space kept on each side of the hardware notch in the top band.
    static let notchClearance: CGFloat = 12
    static let noteRowHeight: CGFloat = 38
}

/// Motion tokens. Everything is one-shot; nothing loops (docs/DESIGN.md section 6).
enum Motion {
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
    static let hover = Animation.easeOut(duration: 0.12)
    static let push = Animation.easeOut(duration: 0.22)
    static let phase = Animation.easeInOut(duration: 0.3)
    static let fade = Animation.easeInOut(duration: 0.15)
    static let entrance = Animation.easeOut(duration: 0.28)
    /// Stagger between panes on expand, after the shape has begun to open.
    static let entranceDelay: Double = 0.02
    static let stagger: Double = 0.035
    static let entranceOffset: CGFloat = 6

    // MARK: Island morph (all open/dismiss timings live here)
    /// Hover intent delays.
    static let hoverOpenDelay: TimeInterval = 0.03
    static let hoverCloseDelay: TimeInterval = 0.10
    /// Shape springs.
    static let openSpring = Animation.spring(response: 0.30, dampingFraction: 0.74)    // slight overshoot
    static let wingsSpring = Animation.spring(response: 0.30, dampingFraction: 0.78)
    static let closeSpring = Animation.spring(response: 0.22, dampingFraction: 1.0)    // critically damped
    static let reducedEase = Animation.easeInOut(duration: 0.15)
    /// Content timing: starts this long after the shape on open; leaves this fast on dismiss.
    static let contentInDelay: TimeInterval = 0.03
    static let contentInReinterruptDelay: TimeInterval = 0.015
    static let contentIn = Animation.easeOut(duration: 0.15)
    static let contentOut = Animation.easeIn(duration: 0.07)
    /// Shape starts shrinking together with the content fade (no extra gap).
    static let shrinkDelay: TimeInterval = 0
    static let wingsFadeOut = Animation.easeOut(duration: 0.08)
    static let wingsFadeIn = Animation.easeOut(duration: 0.12)
    static let wingsInDelay: TimeInterval = 0.08
    /// Time for the close spring to be visually settled, then fade out / unmount.
    static let settleTime: TimeInterval = 0.25
    static let unmountTime: TimeInterval = 0.36
}

/// Colors that depend on Increase Contrast.
struct Palette {
    var increased = false
    let surface = Color.black
    let textPrimary = Color.white
    let textDisabled = Color.white.opacity(0.3)
    let fillHover = Color.white.opacity(0.08)
    let fillPressed = Color.white.opacity(0.14)
    let fillSelected = Color.white.opacity(0.12)
    let track = Color.white.opacity(0.15)
    let warning = Color(red: 1, green: 0.839, blue: 0.039)
    let amber = Color(red: 1.0, green: 0.749, blue: 0.0)
    var textSecondary: Color { .white.opacity(increased ? 0.85 : 0.70) }
    var textTertiary: Color { .white.opacity(increased ? 0.70 : 0.50) }
    var separator: Color { .white.opacity(increased ? 0.30 : 0.12) }

    static func accent(_ phase: PomodoroPhase) -> Color {
        switch phase {
        case .work: return Color(red: 1, green: 0.42, blue: 0.341)
        case .shortBreak: return Color(red: 0.188, green: 0.82, blue: 0.345)
        case .longBreak: return Color(red: 0.392, green: 0.824, blue: 1)
        }
    }
    static func accentNS(_ phase: PomodoroPhase) -> NSColor {
        switch phase {
        case .work: return NSColor(srgbRed: 1, green: 0.42, blue: 0.341, alpha: 1)
        case .shortBreak: return NSColor(srgbRed: 0.188, green: 0.82, blue: 0.345, alpha: 1)
        case .longBreak: return NSColor(srgbRed: 0.392, green: 0.824, blue: 1, alpha: 1)
        }
    }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette() }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

enum Typo {
    static let timeHero = Font.system(size: 40, weight: .semibold).monospacedDigit()
    static let timeCompact = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let rowTitle = Font.body.weight(.semibold)
    static let body = Font.body
    static let snippet = Font.subheadline
    static let tab = Font.subheadline.weight(.semibold)
    static let button = Font.callout.weight(.semibold)
    static let meta = Font.footnote
    static func symbol(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
}

extension PomodoroPhase {
    /// Spec 4.3 glyphs.
    var islandSymbol: String {
        switch self {
        case .work: return "timer"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "moon.zzz.fill"
        }
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    let t = min(99 * 60 + 59, max(0, Int(seconds.rounded(.up))))
    return String(format: "%02d:%02d", t / 60, t % 60)
}

func spokenTime(_ seconds: TimeInterval) -> String {
    let t = max(0, Int(seconds.rounded(.up)))
    return "\(t / 60) minutes \(t % 60) seconds"
}

struct PhaseGlyph: View {
    let phase: PomodoroPhase
    let size: CGFloat
    let color: Color
    var bounceValue: Int = 0

    var body: some View {
        Image(systemName: phase.islandSymbol)
            .font(Typo.symbol(size))
            .symbolRenderingMode(.monochrome)
            .symbolEffect(.bounce, value: bounceValue)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}
