import AppKit
import SwiftUI
import os
import Combine

@main
struct MacNotchApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var panel: NotchPanel?
    private var settingsController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    private var toggleItem: NSMenuItem?
    private var resetItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DebugSettings.installMonitors()
        FocusTracker.start()
        appState.openSettings = { [weak self] in self?.openSettings() }
        setupStatusItem()
        panel = NotchPanel(appState: appState)
        panel?.orderFrontRegardless()

        appState.settings.$showInMenuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.statusItem?.isVisible = on }
            .store(in: &cancellables)

        // Debug: trigger the Notes Automation prompt without needing UI interaction.
        if CommandLine.arguments.contains("--request-automation") {
            Task { await appState.notes.requestAutomationAccess() }
        }
        // Debug: trigger the Accessibility prompt (registers MacNotch in Privacy & Security > Accessibility).
        if CommandLine.arguments.contains("--request-accessibility") {
            NotesProvider.requestAccessibility()
        }

        if CommandLine.arguments.contains("--debug-ax") {
            Logger(subsystem: "com.eortizd.macnotch", category: "ax").notice("debug-ax trusted=\(AXIsProcessTrusted())")
        }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--debug-ax-edit=") }) {
            NotesAX.debugEdit(uri: String(arg.dropFirst("--debug-ax-edit=".count)))
        }
        if CommandLine.arguments.contains("--debug-probe-all") {
            Task { await NotesDebug.probeAll(legacy: CommandLine.arguments.contains("--debug-probe-legacy")) }
        }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--debug-ax-begin=") }) {
            Task { await NotesDebug.axBegin(arg: String(arg.dropFirst("--debug-ax-begin=".count))) }
        }
        if CommandLine.arguments.contains("--debug-fda") {
            let log = Logger(subsystem: "com.eortizd.macnotch", category: "fda")
            for r in NotesDatabase.fdaProbes() {
                log.notice("fda probe \(r.path, privacy: .public) ok=\(r.ok) errno=\(r.errno) (\(String(cString: strerror(r.errno)), privacy: .public))")
            }
            log.notice("fda bundle=\(Bundle.main.bundlePath, privacy: .public) hasFDA=\(NotesDatabase.hasFullDiskAccess())")
        }
        if CommandLine.arguments.contains("--open-settings") { openSettings() }

        if CommandLine.arguments.contains("--debug-start-timer") { appState.pomodoro.toggle() }

        if CommandLine.arguments.contains("--debug-toggle") {
            appState.pomodoro.toggle()
            for i in 1...6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i)) { [weak self] in
                    self?.appState.settings.showTimerWhileCollapsed.toggle()
                }
            }
        }

        // Never unreachable: with the menu bar item hidden, launching opens Settings.
        if !appState.settings.showInMenuBar { openSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: Menu bar extra

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "MacNotch")
        image?.isTemplate = true
        item.button?.image = image
        item.isVisible = appState.settings.showInMenuBar

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let toggle = NSMenuItem(title: "Start Timer", action: #selector(toggleTimer), keyEquivalent: "")
        let reset = NSMenuItem(title: "Reset Timer", action: #selector(resetTimer), keyEquivalent: "")
        let show = NSMenuItem(title: "Show Panel", action: #selector(showPanel), keyEquivalent: "")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Quit MacNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in [toggle, reset, show, settings] { i.target = self }
        menu.addItem(toggle); menu.addItem(reset)
        menu.addItem(.separator())
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu
        toggleItem = toggle
        resetItem = reset
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let e = appState.pomodoro
        toggleItem?.title = e.isRunning ? "Pause Timer" : (e.isPaused ? "Resume Timer" : "Start Timer")
        resetItem?.isEnabled = !e.isIdle
    }

    @objc private func toggleTimer() { appState.pomodoro.toggle() }
    @objc private func resetTimer() { appState.pomodoro.reset() }
    @objc private func showPanel() { panel?.viewModel.expandSticky() }
    @objc private func openSettingsAction() { openSettings() }

    func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(appState: appState) { [weak self] in
                self?.settingsController = nil
            }
        }
        settingsController?.show()
    }
}
