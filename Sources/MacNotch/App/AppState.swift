import Foundation
import Combine

/// Central app state. Engines are created here once and shared with the UI.
@MainActor
final class AppState: ObservableObject {
    let pomodoro: PomodoroEngine
    let notes: NotesProvider
    let settings: AppSettings

    /// Wired by AppDelegate.
    var openSettings: () -> Void = {}
    /// Incremented once per completed phase (drives the one-shot pulse).
    var phaseCompleted: ((PomodoroPhase) -> Void)?

    init() {
        pomodoro = PomodoroEngine()
        notes = NotesProvider()
        settings = AppSettings()
        pomodoro.onPhaseCompleted = { [weak self] phase in
            self?.phaseCompleted?(phase)
        }
    }
}
