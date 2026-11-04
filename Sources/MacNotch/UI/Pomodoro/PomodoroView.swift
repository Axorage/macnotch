import SwiftUI

/// Wing title for the Pomodoro pane (right of the notch).
struct PomodoroBand: View {
    @ObservedObject var engine: PomodoroEngine
    @Environment(\.palette) private var palette

    private var active: Bool { engine.isRunning || engine.isPaused }

    var body: some View {
        HStack(spacing: Space.s) {
            PhaseGlyph(phase: engine.phase, size: 14, color: engine.phase == .work ? palette.amber : (active ? Palette.accent(engine.phase) : palette.textSecondary))
            Text(engine.phase.title)
                .font(Typo.tab)
                .foregroundStyle(palette.textPrimary)
                .contentTransition(.opacity)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, Space.xs)
        .animation(Motion.phase, value: engine.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pomodoro, \(engine.phase.title)")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Ring hero with the countdown, session dots and controls.
struct PomodoroPane: View {
    @ObservedObject var engine: PomodoroEngine
    let pulseID: Int
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: Bool { engine.isRunning || engine.isPaused }
    private var accent: Color { active ? Palette.accent(engine.phase) : palette.textSecondary }
    private var sessionCount: Int { max(1, engine.sessionsBeforeLongBreak) }
    private var sessionNumber: Int {
        engine.phase == .work ? min(sessionCount, engine.completedFocusSessions + 1)
                              : min(sessionCount, max(1, engine.completedFocusSessions))
    }
    private var nextPhase: PomodoroPhase {
        PomodoroEngine.nextPhase(after: engine.phase,
                                 completedFocus: engine.phase == .work ? engine.completedFocusSessions + 1 : engine.completedFocusSessions,
                                 sessionsBeforeLong: sessionCount)
    }
    private var status: String { engine.isPaused ? "Paused" : (engine.isRunning ? "Remaining" : "Ready") }
    private var spoken: String { "\(engine.phase.title), \(spokenTime(engine.remaining)) remaining" }

    var body: some View {
        HStack(spacing: Space.l) {
            ring
                .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : pulseID) { v, s in
                    v.scaleEffect(s)
                } keyframes: { _ in
                    CubicKeyframe(1.05, duration: 0.12)
                    SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                }
            VStack(alignment: .leading, spacing: Space.m) {
                sessions
                controls
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: Ring + time

    private var ring: some View {
        ZStack {
            ProgressRing(engine: engine, size: Metrics.timerRing, line: Metrics.timerRingLine)
            VStack(spacing: 2) {
                time
                Text(status)
                    .font(Typo.meta)
                    .foregroundStyle(palette.textSecondary)
                    .contentTransition(.opacity)
            }
            .animation(Motion.fade, value: status)
        }
        .frame(width: Metrics.timerRing, height: Metrics.timerRing)
        // New identity per phase: ring resets and accent crossfades (opacity only, Reduce Motion safe).
        .id(engine.phase)
        .transition(.opacity)
        .animation(Motion.phase, value: engine.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// Running: system-rendered countdown (no app redraw). Otherwise static text with numericText transition.
    @ViewBuilder private var time: some View {
        let font = Font.system(size: 28, weight: .semibold).monospacedDigit()
        if let end = engine.endDate {
            Text(timerInterval: min(Date(), end)...end, pauseTime: nil, countsDown: true, showsHours: false)
                .font(font)
                .foregroundStyle(palette.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(1).minimumScaleFactor(0.8).frame(width: 92)
        } else {
            Text(formatTime(engine.remaining))
                .font(font)
                .foregroundStyle(engine.isPaused ? palette.textSecondary : palette.textPrimary)
                .contentTransition(.numericText(countsDown: true))
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: Int(engine.remaining))
                .lineLimit(1).minimumScaleFactor(0.8).frame(width: 92)
        }
    }

    // MARK: Sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(0..<sessionCount, id: \.self) { i in
                    Circle()
                        .fill(i < engine.completedFocusSessions ? Palette.accent(.work) : Color.clear)
                        .overlay(Circle().strokeBorder(i < engine.completedFocusSessions ? Color.clear : palette.textSecondary, lineWidth: 1))
                        .frame(width: 7, height: 7)
                }
            }
            Text("Session \(sessionNumber) of \(sessionCount)")
                .font(Typo.meta)
                .foregroundStyle(palette.textSecondary)
        }
        .animation(Motion.phase, value: engine.completedFocusSessions)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session \(sessionNumber) of \(sessionCount)")
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                PrimaryRoundButton(symbol: engine.isRunning ? "pause.fill" : "play.fill",
                                   fill: active ? Palette.accent(engine.phase) : .white,
                                   label: engine.isRunning ? "Pause Timer" : "Start Timer",
                                   value: spoken) { engine.toggle() }
                IconButton(symbol: "arrow.counterclockwise", size: 13, label: "Reset Timer",
                           hint: "Returns to the start of this phase") { engine.reset() }
            }
            nextButton
        }
        .animation(Motion.phase, value: engine.phase)
    }

    /// Always visible; advances to the next phase (idle, running or paused).
    private var nextButton: some View {
        HoverButton(radius: 7, action: { engine.skip() }) {
            HStack(spacing: 6) {
                Image(systemName: "forward.end.fill").font(Typo.symbol(11))
                Text("Next: \(nextPhase.title)")
                    .font(Typo.tab)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, Space.s)
            .frame(minHeight: Metrics.minHit)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
        }
        .help("Next: \(nextPhase.title)")
        .accessibilityLabel("Skip to \(nextPhase.title)")
        .accessibilityHint("Ends this phase and moves to the next one")
    }
}
