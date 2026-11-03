import AppKit
import SwiftUI

/// Created lazily; torn down on close so the SwiftUI hierarchy is not kept in memory.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onClose: () -> Void

    init(appState: AppState, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
        let host = NSHostingController(rootView: SettingsView().environmentObject(appState))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "MacNotch Settings"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        w.standardWindowButton(.zoomButton)?.isEnabled = false
        w.isReleasedWhenClosed = false
        w.delegate = self
        host.view.layoutSubtreeIfNeeded()
        let fit = host.view.fittingSize
        let maxH = (NSScreen.main?.visibleFrame.height ?? 800) - 80   // never taller than the screen; Form scrolls
        let h = fit.height > 100 ? fit.height : 720
        w.setContentSize(NSSize(width: 420, height: min(h, maxH)))
        w.center()
        window = w
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if DebugSettings.enabled {
            DebugSettings.log.notice("Settings show: visible=\(self.window?.isVisible ?? false) key=\(self.window?.isKeyWindow ?? false) frame=\(NSStringFromRect(self.window?.frame ?? .zero), privacy: .public) appActive=\(NSApp.isActive)")
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        onClose()
    }
}
