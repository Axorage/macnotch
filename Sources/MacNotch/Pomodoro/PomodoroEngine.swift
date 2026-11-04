import AppKit
import Combine
import Foundation

/// Pomodoro state machine. No per-second ticking: a single one-shot Timer is
/// scheduled at `endDate`; the UI renders the countdown via Text(timerInterval:).
@MainActor
final class PomodoroEngine: ObservableObject {

    // MARK: Pure transition logic

    /// `completedFocus` is the count INCLUDING the work session just finished
    /// when `phase == .work`.
    nonisolated static func nextPhase(after phase: PomodoroPhase,
                                      completedFocus: Int,
                                      sessionsBeforeLong: Int) -> PomodoroPhase {
        switch phase {
        case .work:
            let n = max(1, sessionsBeforeLong)
            return completedFocus > 0 && completedFocus % n == 0 ? .longBreak : .shortBreak
        case .shortBreak, .longBreak:
            return .work
        }
    }

    // MARK: State

    @Published private(set) var phase: PomodoroPhase { didSet { save(phase.rawValue, "phase") } }
    @Published private(set) var endDate: Date? { didSet { save(endDate, "endDate") } }
    @Published private(set) var pausedRemaining: TimeInterval? { didSet { save(pausedRemaining, "pausedRemaining") } }
    @Published private(set) var completedFocusSessions: Int { didSet { save(completedFocusSessions, "completedFocusSessions") } }

    @Published var workMinutes: Int { didSet { save(workMinutes, "workMinutes") } }
    @Published var shortBreakMinutes: Int { didSet { save(shortBreakMinutes, "shortBreakMinutes") } }
    @Published var longBreakMinutes: Int { didSet { save(longBreakMinutes, "longBreakMinutes") } }
    @Published var sessionsBeforeLongBreak: Int { didSet { save(sessionsBeforeLongBreak, "sessionsBeforeLongBreak") } }
    @Published var soundEnabled: Bool { didSet { save(soundEnabled, "soundEnabled") } }
    @Published var autoStartNext: Bool { didSet { save(autoStartNext, "autoStartNext") } }

    var onPhaseCompleted: ((PomodoroPhase) -> Void)?

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { pausedRemaining != nil }
    var isIdle: Bool { endDate == nil && pausedRemaining == nil }

    func duration(for phase: PomodoroPhase) -> TimeInterval {
        let minutes: Int
        switch phase {
        case .work: minutes = workMinutes
        case .shortBreak: minutes = shortBreakMinutes
        case .longBreak: minutes = longBreakMinutes
        }
        return TimeInterval(max(1, minutes) * 60)
    }

    /// Remaining seconds, computed from the clock (idle: full phase duration).
    var remaining: TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now())) }
        if let pausedRemaining { return pausedRemaining }
        return duration(for: phase)
    }

    /// 0...1 elapsed fraction of the current phase.
    var progress: Double {
        let total = duration(for: phase)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / total))
    }

    // MARK: Private

    private let defaults: UserDefaults
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?

    /// Injectable time sources (tests simulate clock jumps by moving `now` independently of `uptime`).
    var now: () -> Date = { Date() }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Monotonic run anchor, set at start/resume/wake/relaunch. `systemUptime` pauses during
    /// sleep, so the anchor is re-based from the wall clock on wake (sleep time counts).
    private var runAnchorUptime: TimeInterval = 0
    private var runDuration: TimeInterval = 0

    /// Completions detected more than this long after `endDate` never auto-start.
    static let lateAutoStartGrace: TimeInterval = 5
    private var restoring = true
    private static let prefix = "pomodoro."

    // MARK: Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func int(_ k: String, _ d: Int) -> Int {
            defaults.object(forKey: Self.prefix + k) != nil ? defaults.integer(forKey: Self.prefix + k) : d
        }
        func bool(_ k: String, _ d: Bool) -> Bool {
            defaults.object(forKey: Self.prefix + k) != nil ? defaults.bool(forKey: Self.prefix + k) : d
        }
        workMinutes = max(1, int("workMinutes", 25))
        shortBreakMinutes = max(1, int("shortBreakMinutes", 5))
        longBreakMinutes = max(1, int("longBreakMinutes", 15))
        sessionsBeforeLongBreak = max(1, int("sessionsBeforeLongBreak", 4))
        soundEnabled = bool("soundEnabled", true)
        autoStartNext = bool("autoStartNext", false)
        completedFocusSessions = max(0, int("completedFocusSessions", 0))
        phase = (defaults.string(forKey: Self.prefix + "phase")).flatMap(PomodoroPhase.init(rawValue:)) ?? .work
        endDate = defaults.object(forKey: Self.prefix + "endDate") as? Date
        let pr = defaults.object(forKey: Self.prefix + "pausedRemaining") as? Double
        pausedRemaining = (endDate == nil) ? pr : nil
        restoring = false

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }

        clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClockChange() }
        }

        if let end = endDate {
            if end <= now() {
                // Elapsed while the app was closed: finish silently, land idle in next phase.
                endDate = nil
                advance(notify: false, allowAutoStart: false)
            } else {
                rebaseMonotonic(to: end) // wall clock is the only reference across relaunch
                schedule(at: end)
            }
        }
    }

    // MARK: Controls

    func start() {
        if isPaused { resume(); return }
        guard isIdle else { return }
        begin(duration: duration(for: phase))
    }

    func pause() {
        guard let end = endDate else { return }
        let rem = end.timeIntervalSince(now())
        if rem <= 0 { // already elapsed: complete instead of faking a 1 s pause
            complete(end: end)
            return
        }
        cancelTimer()
        pausedRemaining = rem
        endDate = nil
    }

    func resume() {
        guard let rem = pausedRemaining else { return }
        pausedRemaining = nil
        begin(duration: rem)
    }

    func toggle() {
        if isRunning { pause() } else if isPaused { resume() } else { start() }
    }

    /// Stop and return to an idle, full-length current phase (cycle counter kept).
    func reset() {
        cancelTimer()
        endDate = nil
        pausedRemaining = nil
    }

    /// Silently finish the current phase (counts like a completion) and go idle in the next one.
    func skip() {
        cancelTimer()
        endDate = nil
        pausedRemaining = nil
        advance(notify: false, allowAutoStart: false)
    }

    // MARK: Internals

    private func begin(duration: TimeInterval) {
        let end = now().addingTimeInterval(duration)
        runAnchorUptime = uptime()
        runDuration = duration
        endDate = end
        schedule(at: end)
    }

    private func schedule(at date: Date) {
        cancelTimer()
        let t = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func timerFired() {
        timer = nil
        guard let end = endDate else { return }
        if end > now().addingTimeInterval(0.01) { schedule(at: end); return } // fired early
        complete(end: end)
    }

    /// Single completion path (timer, wake, pause-at-zero, clock change). One auto-start policy:
    /// detected more than `lateAutoStartGrace` after `end` -> never auto-start; else honor autoStartNext.
    private func complete(end: Date) {
        cancelTimer()
        let late = now().timeIntervalSince(end) > Self.lateAutoStartGrace
        endDate = nil
        advance(notify: true, allowAutoStart: !late)
    }

    private func handleWake() {
        guard let end = endDate else { return }
        if end <= now() {
            complete(end: end)
        } else {
            rebaseMonotonic(to: end) // sleep time counted via wall clock
            schedule(at: end)        // timers may drift across sleep; re-arm
        }
    }

    /// Wall clock jumped (manual change, NTP, timezone is not affected). Keep the remaining time
    /// measured on the monotonic clock and move `endDate` accordingly.
    private func handleClockChange() {
        guard endDate != nil else { return }
        let rem = runDuration - (uptime() - runAnchorUptime)
        if rem <= 0 {
            complete(end: now()) // monotonic time says it is done; not late
            return
        }
        let end = now().addingTimeInterval(rem)
        runAnchorUptime = uptime()
        runDuration = rem
        endDate = end
        schedule(at: end)
    }

    private func rebaseMonotonic(to end: Date) {
        runAnchorUptime = uptime()
        runDuration = max(0, end.timeIntervalSince(now()))
    }

    /// Complete the current phase and move to the next (idle unless auto-start applies).
    private func advance(notify: Bool, allowAutoStart: Bool) {
        let finished = phase
        if finished == .work { completedFocusSessions += 1 }
        let next = Self.nextPhase(after: finished,
                                  completedFocus: completedFocusSessions,
                                  sessionsBeforeLong: sessionsBeforeLongBreak)
        if finished == .longBreak { completedFocusSessions = 0 }
        phase = next

        if notify {
            if soundEnabled { NSSound(named: "Glass")?.play() }
        }
        if notify { onPhaseCompleted?(finished) }
        if allowAutoStart && autoStartNext { begin(duration: duration(for: next)) }
    }

    // MARK: Persistence

    private func save(_ value: Any?, _ key: String) {
        guard !restoring else { return }
        if let value { defaults.set(value, forKey: Self.prefix + key) }
        else { defaults.removeObject(forKey: Self.prefix + key) }
    }
}
