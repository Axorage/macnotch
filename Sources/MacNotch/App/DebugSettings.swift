import AppKit
import os

/// Zero-cost unless launched with --debug-settings.
enum DebugSettings {
    static let enabled = CommandLine.arguments.contains("--debug-settings")
    static let log = Logger(subsystem: "com.eortizd.macnotch", category: "debug-settings")
    private static var monitor: Any?
    private static var observers: [NSObjectProtocol] = []

    static func watchdog(_ tag: String) {
        guard enabled else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        log.notice("watchdog start \(tag, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let dt = CFAbsoluteTimeGetCurrent() - t0
            log.notice("main responsive \(tag, privacy: .public) after \(dt, format: .fixed(precision: 3))s")
        }
    }

    @MainActor static func installMonitors() {
        guard enabled, monitor == nil else { return }
        log.notice("debug-settings enabled pid=\(ProcessInfo.processInfo.processIdentifier)")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { e in
            let w = e.window
            let loc = NSEvent.mouseLocation
            let frames = NSApp.windows.filter { $0.isVisible }.map { "\(type(of: $0))[\($0.title)] \(NSStringFromRect($0.frame)) lvl=\($0.level.rawValue) key=\($0.isKeyWindow)" }.joined(separator: " | ")
            log.notice("localMonitor type=\(e.type.rawValue) window=\(w.map { "\(type(of: $0))[\($0.title)]" } ?? "nil", privacy: .public) screenLoc=\(NSStringFromPoint(loc), privacy: .public) appActive=\(NSApp.isActive) returns=event windows: \(frames, privacy: .public)")
            return e
        }
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { n in
                let w = n.object as? NSWindow
                log.notice("\(n.name.rawValue, privacy: .public) window=\(w.map { "\(type(of: $0))[\($0.title)]" } ?? "nil", privacy: .public)")
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { n in
                log.notice("\(n.name.rawValue, privacy: .public)")
            })
        }
    }
}
