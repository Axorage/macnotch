import Foundation
import Combine
import CoreGraphics
import AppKit
import SwiftUI
import os

enum IslandLayout: Equatable { case hidden, live, expanded }
enum IslandTransition { case open, close, wings }

enum Log { static let hover = Logger(subsystem: "com.eortizd.macnotch", category: "hover") }

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var liveActive = false
    @Published private(set) var transition: IslandTransition = .wings
    /// Opening a note (editor) makes the panel sticky/key so typing works; closing it releases that.
    @Published var selectedNote: NoteItem? { didSet { selectedNoteChanged() } }
    @Published var highlightedRow: Int64?
    @Published private(set) var pulseID = 0
    @Published private(set) var notchSize: CGSize
    @Published private(set) var hasPhysicalNotch: Bool
    @Published private(set) var expandedBody: CGSize

    let appState: AppState
    private(set) var isSticky = false

    let openDelay: TimeInterval = Motion.hoverOpenDelay
    let closeDelay: TimeInterval = Motion.hoverCloseDelay

    private var pending: DispatchWorkItem?
    private var lingerWork: DispatchWorkItem?
    private var lingering = false { didSet { refreshLive() } }
    private var cancellables = Set<AnyCancellable>()
    private var outsideMonitor: Any?
    private var notesStarted = false

    /// Called when sticky mode changes (panel makes itself key / resigns).
    var onStickyChange: ((Bool) -> Void)?
    /// True when the pointer is currently inside the (post-change) island rect.
    var isPointerInIsland: () -> Bool = { false }
    private var suppressHover = false
    /// Sticky because of an explicit request (menu / accessibility), not because an editor is open.
    private var pinned = false

    init(geometry: NotchGeometry, appState: AppState) {
        self.appState = appState
        notchSize = geometry.notchSize
        hasPhysicalNotch = geometry.hasPhysicalNotch
        let s = appState.settings
        expandedBody = CGSize(width: geometry.expandedSize.width - Metrics.expandedEar * 2,
                              height: geometry.expandedSize.height)

        s.$showTimerWhileCollapsed
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLive() }
            .store(in: &cancellables)

        appState.pomodoro.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.engineChanged() }
            .store(in: &cancellables)

        appState.phaseCompleted = { [weak self] phase in self?.phaseCompleted(phase) }
        refreshLive()
    }

    func update(geometry: NotchGeometry) {
        notchSize = geometry.notchSize
        hasPhysicalNotch = geometry.hasPhysicalNotch
    }

    // MARK: Layout

    var layout: IslandLayout {
        if isExpanded { return .expanded }
        if liveActive { return .live }
        return .hidden
    }

    /// Header row height (spec 2.4).
    var headerHeight: CGFloat { hasPhysicalNotch ? notchSize.height : 28 }

    /// Visible island frame size including ears; zero when nothing is drawn.
    var currentSize: CGSize {
        switch layout {
        case .hidden: return .zero
        case .live: return CGSize(width: notchSize.width + Metrics.wing * 2 + Metrics.liveEar * 2, height: notchSize.height)
        case .expanded: return CGSize(width: expandedBody.width + Metrics.expandedEar * 2, height: expandedBody.height)
        }
    }

    /// Region that reacts to hover/click: the drawn island, or (hidden) the hardware notch plus a little slop below.
    var interactiveSize: CGSize {
        switch layout {
        case .hidden:
            return hasPhysicalNotch ? CGSize(width: notchSize.width, height: notchSize.height + NotchGeometry.hoverSlopBelow) : .zero
        default: return currentSize
        }
    }

    var expandedSizeForDebug: CGSize { CGSize(width: expandedBody.width + Metrics.expandedEar * 2, height: expandedBody.height) }

    // MARK: Engine

    private func engineChanged() {
        if appState.pomodoro.isRunning || appState.pomodoro.isPaused { lingering = false; lingerWork?.cancel() }
        refreshLive()
    }

    private func refreshLive() {
        let e = appState.pomodoro
        let live = (e.isRunning || e.isPaused || lingering) && appState.settings.showTimerWhileCollapsed
        guard live != liveActive else { return }
        if !isExpanded { transition = .wings }
        Log.hover.notice("liveActive -> \(live)")
        liveActive = live
    }

    private func phaseCompleted(_ phase: PomodoroPhase) {
        let e = appState.pomodoro
        lingering = true
        lingerWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.lingering = false }
        lingerWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: w)
        pulseID += 1
        let msg = "\(phase.title) complete. \(e.phase.title) is ready."
        AccessibilityNotification.Announcement(msg).post()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    // MARK: Open / close

    // Hover is a geometric state machine with strict ownership:
    //  - hidden / wings: only the HoverSensorPanel counts (sensorEntered/sensorExited).
    //  - expanded: sensor events are ignored; only the main panel's tracking area (panelPointer) can start a
    //    close, and every exit is confirmed against the TARGET expanded rect (NSEvent.mouseLocation), so
    //    events synthesized by toggling ignoresMouseEvents / ordering windows never count as user hover.

    /// Pointer inside the sensor (collapsed island) rect, screen coordinates. Set by the panel.
    var isPointerInSensor: () -> Bool = { false }
    /// Pointer inside the final expanded island rect (+slop), screen coordinates. Set by the panel.
    var isPointerInExpandedTarget: () -> Bool = { false }
    /// After expanding, exits are only honoured if the pointer is really outside the expanded rect.
    private static let expandHysteresis: TimeInterval = 0.15

    func sensorEntered() {
        guard !isExpanded else { return }
        pending?.cancel()
        Log.hover.notice("sensor enter")
        guard !suppressHover, hasPhysicalNotch, NSEvent.pressedMouseButtons == 0 else { return }
        schedule(after: openDelay) { [weak self] in
            guard let self, !self.isExpanded, self.isPointerInSensor() else { return }
            self.setExpanded(true, sticky: false)
        }
    }

    func sensorExited() {
        guard !isExpanded else { return }
        pending?.cancel()
        suppressHover = false
        Log.hover.notice("sensor exit")
    }

    /// Panel tracking-area enter/exit (and reconcile). Only meaningful while expanded.
    func panelPointer(inside: Bool) {
        guard isExpanded, !isSticky else { return }
        pending?.cancel()
        if inside { return }
        evaluateExit()
    }

    /// Start a close timer if the pointer is outside the expanded target; confirm again when it fires.
    private func evaluateExit() {
        guard isExpanded, !isSticky, !isPointerInExpandedTarget() else { return }
        Log.hover.notice("exit candidate (pointer outside expanded rect)")
        schedule(after: closeDelay) { [weak self] in
            guard let self, self.isExpanded, !self.isSticky, !self.isPointerInExpandedTarget() else { return }
            self.setExpanded(false, sticky: false)
        }
    }

    private func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: block)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Expand immediately without pinning (click on the collapsed notch).
    func expandNow() { pending?.cancel(); setExpanded(true, sticky: false) }
    func expandSticky() { pending?.cancel(); pinned = true; setExpanded(true, sticky: true) }
    func makeSticky() { guard isExpanded, !isSticky else { return }; pending?.cancel(); setSticky(true) }

    private func selectedNoteChanged() {
        if selectedNote != nil {
            if isExpanded { pending?.cancel(); setSticky(true) }
        } else if isSticky, !pinned, isExpanded {
            setSticky(false)
            // Editor closed: if the pointer already left while it was open, dismiss as for a normal hover-out.
            if !isPointerInIsland() { schedule(after: closeDelay) { [weak self] in self?.setExpanded(false, sticky: false) } }
        }
    }
    func collapse() {
        pending?.cancel()
        setExpanded(false, sticky: false)
        // Don't instantly reopen if the pointer is still sitting over the collapsed island.
        suppressHover = isPointerInIsland()
    }

    private func setExpanded(_ expanded: Bool, sticky: Bool) {
        pending?.cancel()
        Log.hover.notice("setExpanded \(expanded) sticky=\(sticky)")
        appState.notes.isViewing = expanded
        if expanded {
            if !notesStarted { notesStarted = true; appState.notes.start() }
            appState.notes.refreshIfNeeded()
        }
        if expanded != isExpanded {
            transition = expanded ? .open : .close
            isExpanded = expanded
            if expanded {
                // The pointer may already have left before the panel's tracking area was live: re-check once.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandHysteresis) { [weak self] in
                    self?.evaluateExit()
                }
            }
        }
        if !expanded { selectedNote = nil; highlightedRow = nil }
        if !expanded || !sticky { pinned = false }
        setSticky(expanded && (sticky || selectedNote != nil))
    }

    private func setSticky(_ on: Bool) {
        guard on != isSticky else { return }
        isSticky = on
        if on {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.collapse() }
            }
        } else if let m = outsideMonitor {
            NSEvent.removeMonitor(m)
            outsideMonitor = nil
        }
        onStickyChange?(on)
    }

    // MARK: Commands (shared by keyboard, menu, accessibility)

    func openNote(_ n: NoteItem) { selectedNote = n }
    func closeNote() { selectedNote = nil }

    func openSelectedInNotes() {
        guard let n = selectedNote else { return }
        appState.notes.openInNotes(n)
        collapse()
    }

    /// Returns true if the key was handled. Only called while the panel is key.
    func handleKey(keyCode: UInt16, command: Bool, textFocused: Bool) -> Bool {
        // While the note editor has focus, everything belongs to the text view except Esc (save and go back)
        // and Command-S (save now). Space, Return, arrows and Command-R must reach the text.
        if textFocused, let session = appState.notes.activeSession {
            if command { if keyCode == 1 { Task { await session.saveNow() }; return true }; return false }
            if keyCode == 53 {
                Task { if await session.finish() { closeNote() } }
                return true
            }
            return false
        }
        let e = appState.pomodoro
        if command {
            switch keyCode {
            case 15: e.reset(); return true               // R
            case 124: e.skip(); return true               // right arrow
            case 43: appState.openSettings(); return true // ,
            default: return false
            }
        }
        switch keyCode {
        case 53: // Esc
            if selectedNote != nil { closeNote() } else { collapse() }
            return true
        case 49 where !textFocused: e.toggle(); return true
        case 125, 126: return moveHighlight(down: keyCode == 125)
        case 36, 76:
            if selectedNote == nil, let id = highlightedRow,
               let n = appState.notes.notes.first(where: { $0.id == id }) { openNote(n); return true }
            return false
        default: return false
        }
    }

    private func moveHighlight(down: Bool) -> Bool {
        guard selectedNote == nil else { return false }
        let notes = appState.notes.notes
        guard !notes.isEmpty else { return false }
        let idx = highlightedRow.flatMap { id in notes.firstIndex { $0.id == id } }
        let next: Int
        if let idx { next = min(notes.count - 1, max(0, idx + (down ? 1 : -1))) } else { next = down ? 0 : notes.count - 1 }
        highlightedRow = notes[next].id
        return true
    }
}
