import SwiftUI

/// Compact live activity: phase glyph on the left, time on the right.
/// Both wings are a single accessibility element and share one click target (handled by the panel).
struct LiveWingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1

    var body: some View {
        WingsContent(engine: appState.pomodoro, pulseID: viewModel.pulseID, notchWidth: viewModel.notchSize.width)
            .scaleEffect(scale)
            .onChange(of: viewModel.pulseID) { _, _ in pulse() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint("Opens MacNotch")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { viewModel.expandSticky() }
            .accessibilityAction(named: appState.pomodoro.isRunning ? "Pause Timer" : "Start Timer") { appState.pomodoro.toggle() }
    }

    private var label: String {
        let e = appState.pomodoro
        let state = e.isRunning ? "running" : (e.isPaused ? "paused" : "ready")
        return "\(e.phase.title) timer, \(spokenTime(e.remaining)) remaining, \(state)"
    }

    private func pulse() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { scale = 1.06 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { scale = 1 }
        }
    }
}

private struct WingsContent: View {
    @ObservedObject var engine: PomodoroEngine
    let pulseID: Int
    let notchWidth: CGFloat
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: Bool { engine.isRunning || engine.isPaused }
    private var accent: Color { active ? Palette.accent(engine.phase) : palette.textSecondary }

    var body: some View {
        HStack(spacing: 0) {
            // Glyph only (no ring). Paused: same glyph at reduced opacity, time turns secondary.
            PhaseGlyph(phase: engine.phase, size: 14, color: accent, bounceValue: reduceMotion ? 0 : pulseID)
                .opacity(engine.isPaused ? 0.5 : 1)
                .id(reduceMotion ? engine.phase.rawValue : "g")
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                .frame(maxHeight: .infinity)
                .padding(.leading, 10)
                .frame(width: Metrics.wing, alignment: .leading)

            Spacer(minLength: 0).frame(width: notchWidth)

            TimeText(engine: engine, font: Typo.timeCompact,
                     color: engine.isPaused || engine.isIdle ? palette.textSecondary : palette.textPrimary,
                     fixedWidth: Metrics.compactTimeWidth)
                .padding(.trailing, 10)
                .frame(width: Metrics.wing, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, Metrics.liveEar)
    }
}

/// Remaining time. Running: system-rendered countdown (no app redraws). Otherwise plain text.
struct TimeText: View {
    @ObservedObject var engine: PomodoroEngine
    let font: Font
    let color: Color
    /// Optional fixed width (sized for "00:00") so the system-rendered countdown never jitters.
    var fixedWidth: CGFloat? = nil

    var body: some View {
        Group {
            if let end = engine.endDate {
                Text(timerInterval: min(Date(), end)...end, pauseTime: nil, countsDown: true, showsHours: false)
            } else {
                Text(formatTime(engine.remaining))
            }
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: fixedWidth, alignment: .trailing)
        .fixedSize(horizontal: fixedWidth == nil, vertical: true)
    }
}

struct ProgressRing: View {
    @ObservedObject var engine: PomodoroEngine
    let size: CGFloat
    let line: CGFloat
    @Environment(\.palette) private var palette

    private struct Key: Hashable { var end: Date?; var paused: Double?; var phase: PomodoroPhase; var total: Double }

    var body: some View {
        let active = engine.isRunning || engine.isPaused
        CAProgress(style: .ring(diameter: size, line: line),
                   color: Palette.accentNS(engine.phase),
                   trackColor: NSColor(white: 1, alpha: 0.15),
                   progress: active ? engine.progress : 0,
                   remaining: engine.remaining,
                   running: engine.isRunning,
                   key: Key(end: engine.endDate, paused: engine.pausedRemaining, phase: engine.phase,
                            total: engine.duration(for: engine.phase)))
            .frame(width: size, height: size)
    }
}
