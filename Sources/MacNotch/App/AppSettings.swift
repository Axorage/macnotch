import Foundation
import Combine

/// UI-level preferences (Pomodoro and Notes preferences live in their engines).
@MainActor
final class AppSettings: ObservableObject {
    static let widthRange: ClosedRange<Double> = 360...520
    static let heightRange: ClosedRange<Double> = 160...240

    private let defaults = UserDefaults.standard

    @Published var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: "ui.showInMenuBar") } }
    /// Draw the timer wings while collapsed + running (default off: collapsed draws nothing).
    @Published var showTimerWhileCollapsed: Bool { didSet {
        if DebugSettings.enabled { DebugSettings.log.notice("AppSettings.showTimerWhileCollapsed didSet \(self.showTimerWhileCollapsed)") }
        defaults.set(showTimerWhileCollapsed, forKey: "ui.showTimerWhileCollapsed")
    } }
    @Published var panelWidth: Double { didSet { defaults.set(panelWidth, forKey: "ui.panelWidth") } }
    @Published var panelHeight: Double { didSet { defaults.set(panelHeight, forKey: "ui.panelHeight") } }

    init() {
        let d = UserDefaults.standard
        showInMenuBar = d.object(forKey: "ui.showInMenuBar") as? Bool ?? true
        showTimerWhileCollapsed = d.object(forKey: "ui.showTimerWhileCollapsed") as? Bool ?? false
        let w = d.object(forKey: "ui.panelWidth") as? Double ?? 420
        let h = d.object(forKey: "ui.panelHeight") as? Double ?? 180
        panelWidth = min(max(w, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        panelHeight = min(max(h, Self.heightRange.lowerBound), Self.heightRange.upperBound)
    }
}
