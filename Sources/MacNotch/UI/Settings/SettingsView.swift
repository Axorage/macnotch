import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            GeneralSection(settings: appState.settings)
            NotesSection(notes: appState.notes)
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

private struct NotesSection: View {
    @ObservedObject var notes: NotesProvider
    @State private var text = ""
    @State private var useOther = false
    @State private var debounce: Task<Void, Never>?

    private static let otherTag = "\u{0}other"

    private var options: [String] {
        var list = notes.availableFolders
        if !useOther, !list.contains(where: { $0.caseInsensitiveCompare(notes.folderName) == .orderedSame }) {
            list.insert(notes.folderName, at: 0)
        }
        return list
    }

    private var selection: Binding<String> {
        Binding(
            get: { useOther ? Self.otherTag : (options.first { $0.caseInsensitiveCompare(notes.folderName) == .orderedSame } ?? notes.folderName) },
            set: { new in
                if new == Self.otherTag { useOther = true; text = notes.folderName }
                else { useOther = false; notes.folderName = new }
            })
    }

    var body: some View {
        Section("Notes") {
            if notes.availableFolders.isEmpty && !useOther {
                // Folder list not available (Notes closed or no access): fall back to typing the name.
                nameField
            } else {
                Picker("Folder", selection: selection) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Other\u{2026}").tag(Self.otherTag)
                }
                if useOther { nameField }
            }
            Text(statusLine).font(.footnote).foregroundStyle(.secondary)
            if case .folderNotFound = notes.status {
                Button("Create \u{201C}\(notes.folderName)\u{201D} Folder") { Task { await notes.createFolder() } }
            }
        }
        .onAppear {
            text = notes.folderName
            notes.refreshIfNeeded()
            notes.loadFolders(force: true)
        }
        .onChange(of: notes.availableFolders) { _, list in
            if !list.isEmpty, !useOther, !list.contains(where: { $0.caseInsensitiveCompare(notes.folderName) == .orderedSame }) {
                useOther = true   // current folder isn't in Notes (yet): keep it editable
            }
        }
    }

    private var nameField: some View {
        TextField("Folder Name", text: $text)
            .onChange(of: text) { _, new in
                debounce?.cancel()
                debounce = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if !Task.isCancelled, !new.isEmpty { notes.folderName = new }
                }
            }
    }

    private var statusLine: String {
        switch notes.status {
        case .ok: return "✓ Found · \(notes.notes.count) unlocked notes"
        case .empty: return "✓ Found · No notes yet"
        case .folderNotFound: return "⚠ No folder with this name in Notes"
        case .loading: return "Checking…"
        case .needsFullDiskAccess: return "Full Disk Access needed to read Notes"
        case .needsAutomationAccess: return "Notes access is off. Hover the notch to allow it."
        case .notesNotRunning: return "Open Notes to check this folder"
        case .error: return "Notes didn’t respond"
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
