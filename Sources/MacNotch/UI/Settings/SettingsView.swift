import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            GeneralSection(settings: appState.settings)
            PermissionsSection()
            PomodoroSection(engine: appState.pomodoro)
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, maxWidth: 420, minHeight: 300)
    }
}

private struct GeneralSection: View {
    @ObservedObject var settings: AppSettings
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    private let canManageLogin = Bundle.main.bundlePath.hasSuffix(".app")

    var body: some View {
        Section("General") {
            Toggle("Launch at Login", isOn: Binding(
                get: { loginEnabled },
                set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {}
                    loginEnabled = SMAppService.mainApp.status == .enabled
                }))
                .disabled(!canManageLogin)
            if !canManageLogin {
                Text("Available when running MacNotch.app.").font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Show in Menu Bar", isOn: $settings.showInMenuBar)
            Toggle("Show Timer Next to Notch While Running", isOn: Binding(
                get: {
                    if DebugSettings.enabled { DebugSettings.log.notice("toggle get -> \(settings.showTimerWhileCollapsed)") }
                    return settings.showTimerWhileCollapsed
                },
                set: { v in
                    if DebugSettings.enabled { DebugSettings.log.notice("toggle set <- \(v)"); DebugSettings.watchdog("toggle") }
                    settings.showTimerWhileCollapsed = v
                }))
            LabeledContent("Panel Width") {
                HStack {
                    Slider(value: $settings.panelWidth, in: AppSettings.widthRange, step: 10)
                    Text("\(Int(settings.panelWidth)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
            LabeledContent("Panel Height") {
                HStack {
                    Slider(value: $settings.panelHeight, in: AppSettings.heightRange, step: 10)
                    Text("\(Int(settings.panelHeight)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
        }
    }
}

private struct PomodoroSection: View {
    @ObservedObject var engine: PomodoroEngine

    var body: some View {
        Section("Pomodoro") {
            row("Focus", $engine.workMinutes, 1...90, "min")
            row("Short Break", $engine.shortBreakMinutes, 1...30, "min")
            row("Long Break", $engine.longBreakMinutes, 1...60, "min")
            row("Long Break After", $engine.sessionsBeforeLongBreak, 1...12, "focus sessions")
            Toggle("Play Sound When a Phase Ends", isOn: $engine.soundEnabled)
        }
    }

    private func row(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, _ unit: String) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue) \(unit)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
