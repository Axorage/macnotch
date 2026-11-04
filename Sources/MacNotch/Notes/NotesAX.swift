import Foundation
import AppKit
import ApplicationServices
import os

/// Edits a note THROUGH Notes' own text view with Accessibility attributes (never keystrokes), so images,
/// tables, checklists and formatting that MacNotch cannot round-trip through HTML stay untouched.
///
/// Everything here is blocking and must run off the main thread (`NotesAX.run`). Every AX element carries a 1 s
/// messaging timeout and every loop is bounded.
enum NotesAX {
    static let log = Logger(subsystem: "com.eortizd.macnotch", category: "ax-edit")
    static let failMessage = "Couldn\u{2019}t save \u{2014} open in Notes to check."
    static let queue = DispatchQueue(label: "macnotch.notes.ax", qos: .userInitiated)

    enum BeginResult: Equatable {
        case ready(String)      // Notes' AX text for the note (attachments are U+FFFC)
        case notTrusted, unavailable, notSettable
    }
    enum WriteResult: Equatable {
        case saved, conflict, failed(String)
    }
    struct Outcome {
        var result: WriteResult; var refocus: Bool
        /// Notes' plaintext / modification seconds right after a successful write (the next conflict baseline).
        var newPlain: String?; var newMod: Int?
        init(result: WriteResult, refocus: Bool) { self.result = result; self.refocus = refocus }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in queue.async { c.resume(returning: work()) } }
    }

    // MARK: AX primitives

    private static var notesApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first
    }

    static func locate() -> AXUIElement? {
        guard AXIsProcessTrusted(), let app = notesApp else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.0)
        var windows: [AXUIElement] = []
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w = NotesLineJump.element(root, attr) { windows.append(w) }
        }
        var list: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &list) == .success, let arr = list as? [AXUIElement] {
            windows += arr
        }
        for w in windows {
            if let area = NotesLineJump.findTextArea(in: w) {
                AXUIElementSetMessagingTimeout(area, 1.0)
                return area
            }
        }
        return nil
    }

    static func value(of area: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(area, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func selectedRange(of area: AXUIElement) -> NSRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let bv = v, CFGetTypeID(bv) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(bv as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    private static func selectedText(of area: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(area, kAXSelectedTextAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func isSettableForDebug(_ a: AXUIElement, _ attr: String) -> Bool { isSettable(a, attr) }
    static func showInBackgroundForDebug(_ uri: String) -> Bool { showInBackground(uri) }
    static func selectedIDForDebug() -> String { selectedID() }

    private static func isSettable(_ area: AXUIElement, _ attr: String) -> Bool {
        var b: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(area, attr as CFString, &b) == .success && b.boolValue
    }

    private static func select(_ area: AXUIElement, _ r: NSRange) -> Bool {
        var cf = CFRange(location: r.location, length: r.length)
        guard let v = AXValueCreate(.cfRange, &cf),
              AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, v) == .success,
              let back = selectedRange(of: area) else { return false }
        return back == r
    }

    /// Polls the area's value until it equals `expected` (the view updates a moment after the attribute set).
    private static func waitForValue(_ area: AXUIElement, _ expected: String, tries: Int = 8) -> Bool {
        for i in 0..<tries {
            if let v = value(of: area), v.utf16.elementsEqual(expected.utf16) { return true }
            if i < tries - 1 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return false
    }

    /// Identity comparison of Notes' AX text and its AppleScript plaintext. Spacing details (nbsp, tabs, U+2028, line
    /// breaks) and attachment characters never matter; if list markers or bullets still make the two differ, only
    /// the letters and digits are compared (they identify the note; offsets always come from the AX text itself).
    static func looselyEqual(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String, alnumOnly: Bool) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.filter {
                alnumOnly ? CharacterSet.alphanumerics.contains($0)
                          : !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{FFFC}"
            }))
        }
        return norm(a, alnumOnly: false) == norm(b, alnumOnly: false) || norm(a, alnumOnly: true) == norm(b, alnumOnly: true)
    }

    // MARK: Focus bookkeeping
    //
    // Root cause of "Notes steals focus": AppleScript `show` makes Notes frontmost (verified: frontmost app goes from the
    // user's app to Notes right after `tell application "Notes" to show note ...`). The old code restored focus with
    // NSRunningApplication.activate(), which on macOS 14+ is cooperative and is ignored when the caller (MacNotch) is not
    // the active app, and it read `isActive` from a background thread (stale). Notes therefore stayed frontmost, and the
    // next click in the notch then recorded Notes as the "previous app" (log: `activateForTyping ... prev=Notes`).
    // Now the frontmost app is read live through Accessibility and put back through AXFrontmost (not cooperative).

    struct FocusMemory {
        /// App to give focus back to: the frontmost app when the operation started (never Notes).
        var target: pid_t?
        var notesWasFront: Bool
        var notesWasHidden: Bool
    }

    /// Live frontmost pid (system-wide AX focused application; no cached NSWorkspace state).
    static func frontPID() -> pid_t? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 1.0)
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &v) == .success,
           let e = v, CFGetTypeID(e) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(e as! AXUIElement, &pid) == .success, pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func name(of pid: pid_t?) -> String {
        guard let pid else { return "-" }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid\(pid)"
    }

    static func bringFront(_ pid: pid_t) {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 1.0)
        if AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
    }

    private static let openLock = NSLock()
    nonisolated(unsafe) private static var _notchOpen = false
    /// Mirrors NotesProvider.isViewing (the island is expanded); readable from the AX queue.
    static var notchOpen: Bool {
        get { openLock.lock(); defer { openLock.unlock() }; return _notchOpen }
        set { openLock.lock(); _notchOpen = newValue; openLock.unlock() }
    }

    /// Captured once, before any Notes interaction of this step. Notes and a missing front app never count as "previous".
    static func remember() -> FocusMemory {
        let n = notesApp
        let front = frontPID()
        var target = front
        // Notes never counts as "previous"; MacNotch itself only while the notch is open (a collapse save runs while
        // MacNotch is still technically frontmost, and focus must then go to the app the user came from).
        if target == nil || target == n?.processIdentifier
            || (target == ProcessInfo.processInfo.processIdentifier && !notchOpen) { target = FocusTracker.lastExternalPID }
        let m = FocusMemory(target: target, notesWasFront: front != nil && front == n?.processIdentifier,
                            notesWasHidden: n?.isHidden ?? false)
        log.notice("focus: capture front=\(name(of: front), privacy: .public) target=\(name(of: target), privacy: .public) notesHidden=\(m.notesWasHidden)")
        return m
    }

    /// Takes focus back from Notes if this operation brought it forward (Notes activates a moment after `show`, so
    /// `settle` waits briefly for that), and re-hides Notes when it was hidden before. True when focus was taken back.
    @discardableResult
    static func restore(_ m: FocusMemory, settle: Bool, step: String) -> Bool {
        guard let notes = notesApp else { return false }
        let npid = notes.processIdentifier
        var front = frontPID()
        if settle && !m.notesWasFront {
            for _ in 0..<8 where front != npid { Thread.sleep(forTimeInterval: 0.05); front = frontPID() }
        }
        log.notice("focus: \(step, privacy: .public) front=\(name(of: front), privacy: .public)")
        var fixed = false
        if front == npid && !m.notesWasFront {
            if let t = m.target, t != npid, NSRunningApplication(processIdentifier: t)?.isTerminated == false {
                bringFront(t)
                Thread.sleep(forTimeInterval: 0.05)
                fixed = true
            }
        }
        if m.notesWasHidden { notes.hide() }
        if fixed { log.notice("focus: \(step, privacy: .public) re-activated \(name(of: m.target), privacy: .public); now front=\(name(of: frontPID()), privacy: .public)") }
        return fixed
    }

    @MainActor static func refocusPanel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                guard let panel = NSApp.windows.compactMap({ $0 as? NotchPanel }).first,
                      let tv = panel.firstResponder as? IslandTextView else { return }
                panel.focusEditor(tv, reason: "ax-restore")
            }
        }
    }

    // MARK: Showing the note

    private static func showInBackground(_ uri: String) -> Bool {
        if case .success(let s) = NotesScripting.shared.runBlocking(NotesScripting.showInBackgroundScript(uri: uri)) { return s == "OK" }
        return false
    }

    private static func selectedID() -> String {
        if case .success(let s) = NotesScripting.shared.runBlocking(NotesScripting.selectedNoteIDScript) { return s }
        return ""
    }

    /// `show` (once per save) without leaving Notes frontmost: see the focus notes above.
    private static func showNote(_ uri: String, mem: FocusMemory, step: String, fixed: inout Bool) -> Bool {
        let ok = showInBackground(uri)
        if restore(mem, settle: true, step: step) { fixed = true }
        return ok
    }

    // MARK: Lazy state (read-only AppleScript; never shows or activates Notes)

    struct NoteState { var attachments: Int; var mod: Int; var plain: String }
    enum StateResult { case ok(NoteState), locked, failed }

    static func readState(uri: String) -> StateResult {
        guard case .success(let out) = NotesScripting.shared.runBlocking(NotesScripting.lazyStateScript(uri: uri)) else { return .failed }
        if out == "!LOCKED" { return .locked }
        let f = out.components(separatedBy: NotesScripting.fieldSep)
        guard f.count >= 3, let att = Int(f[0]), let mod = Int(f[1]) else { return .failed }
        return .ok(NoteState(attachments: att, mod: mod, plain: f[2...].joined(separator: NotesScripting.fieldSep)))
    }

    // MARK: Write (lazy)
    //
    // Nothing touches Notes' UI until a save is needed. A save runs here, once per batch of edits:
    //   a. capture the user's real frontmost app, b. conflict pre-check through scripting (no UI),
    //   c. `show` the note, wait for the AX text area, check it still matches the baseline, apply the minimal diff,
    //   d. immediately give focus back (and re-hide Notes if it was hidden), e. report the new baseline.

    /// `baseline` is the editor's text when it last matched Notes (offsets of the diff); `basePlain` / `baseMod` are
    /// what AppleScript reported for the note then (conflict check). `attachments` must not change.
    static func write(uri: String, basePlain: String, baseMod: Int, baseline: String, target: String, attachments: Int) -> Outcome {
        guard AXIsProcessTrusted() else { return Outcome(result: .failed("Allow Accessibility to save."), refocus: false) }
        guard let edits = NotesTextDiff.edits(from: baseline, to: target) else {
            log.notice("write: placeholder mismatch")
            return Outcome(result: .failed(failMessage), refocus: false)
        }
        if edits.isEmpty { return Outcome(result: .saved, refocus: false) }
        guard notesApp != nil else { return Outcome(result: .failed("Open Notes to save."), refocus: false) }
        // a. before anything touches Notes
        let mem = remember()
        log.notice("lazy: save start front=\(name(of: frontPID()), privacy: .public) target=\(name(of: mem.target), privacy: .public) edits=\(edits.count)")
        var activated = false
        var out = Outcome(result: .failed(failMessage), refocus: false)
        let result = writeInner(uri: uri, basePlain: basePlain, baseMod: baseMod, baseline: baseline, target: target,
                                edits: edits, attachments: attachments, mem: mem, activated: &activated, out: &out)
        activated = restore(mem, settle: true, step: "save end") || activated
        log.notice("lazy: after restore front=\(name(of: frontPID()), privacy: .public) restored=\(activated)")
        out.result = result
        out.refocus = activated || mem.target == ProcessInfo.processInfo.processIdentifier
        log.notice("lazy: save end result=\(String(describing: result), privacy: .public)")
        return out
    }

    private static func writeInner(uri: String, basePlain: String, baseMod: Int, baseline: String, target: String, edits: [TextEdit],
                                   attachments: Int, mem: FocusMemory, activated: inout Bool, out: inout Outcome) -> WriteResult {
        // b. Conflict pre-check without any UI.
        switch readState(uri: uri) {
        case .locked: return .failed("This note is locked.")
        case .failed: return .failed(failMessage)
        case .ok(let st):
            if st.attachments != attachments || !st.plain.utf16.elementsEqual(basePlain.utf16) {
                log.notice("lazy: conflict (pre-check) mod \(baseMod) -> \(st.mod)")
                return .conflict
            }
        }
        // c. Show the note (once), wait for its text view.
        guard showNote(uri, mem: mem, step: "lazy: after show", fixed: &activated) else { return .failed(failMessage) }
        var found: (AXUIElement, String)?
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.075)
            guard let area = locate(), let v = value(of: area), looselyEqual(v, basePlain) else { continue }
            let sel = selectedID()
            if !sel.isEmpty, sel != uri { continue }
            found = (area, v)
            break
        }
        guard let (area, now) = found, isSettable(area, kAXSelectedTextAttribute) else {
            log.notice("write: text area / note not found in time")
            return .failed(failMessage)
        }
        // Editor coordinates -> Notes' AX coordinates.
        guard let map = offsetMap(editor: Array(baseline.utf16), ax: Array(now.utf16)) else {
            log.notice("write: cannot align editor text with Notes' text")
            return .failed(failMessage)
        }
        let ed = Array(baseline.utf16), ax = Array(now.utf16)
        var mapped: [TextEdit] = []
        for e in edits {
            let s = e.range.location, l = e.range.length
            guard s >= 0, s + l <= ed.count else { return .failed(failMessage) }
            let start = map[s]
            var end = start
            if l > 0 {
                end = map[s + l - 1] + 1
                guard end <= ax.count, end >= start, end - start >= l,
                      sameText(Array(ed[s..<(s + l)]), Array(ax[start..<end])) else {
                    log.notice("write: edit range does not align")
                    return .failed(failMessage)
                }
            }
            mapped.append(TextEdit(range: NSRange(location: start, length: end - start), replacement: e.replacement))
        }
        var expected = now
        for e in mapped { expected = NotesTextDiff.apply(e, to: expected) }
        // Apply back to front, verifying every step.
        _ = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let (ok, reached) = apply(mapped, to: now, in: area)
        guard ok else {
            log.notice("write: step failed, rolling back")
            if let rest = NotesTextDiff.edits(from: reached, to: now), !rest.isEmpty { _ = apply(rest, to: reached, in: area) }
            return .failed(failMessage)
        }
        guard waitForValue(area, expected) else { return .failed(failMessage) }
        // The note model itself must reflect the edit; its plaintext and date become the new baseline.
        for i in 0..<12 {
            if case .ok(let st) = readState(uri: uri) {
                if st.attachments != attachments {
                    log.error("write: attachment count changed \(attachments) -> \(st.attachments)")
                    return .failed(failMessage)
                }
                if looselyEqual(st.plain, expected) { out.newPlain = st.plain; out.newMod = st.mod; return .saved }
            }
            if i < 11 { Thread.sleep(forTimeInterval: 0.25) }
        }
        log.error("write: note model did not reflect the edit")
        return .failed(failMessage)
    }

    // MARK: Editor <-> AX coordinates

    private static func norm(_ u: UInt16) -> UInt16 {
        switch u {
        case 0xA0: return 32
        case 0x2028, 0x2029: return 10
        default: return u
        }
    }

    private static func sameText(_ a: [UInt16], _ b: [UInt16]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { norm($0) == norm($1) }
    }

    private static func agree(_ p: [UInt16], _ i: Int, _ a: [UInt16], _ j: Int) -> Bool {
        let n = min(3, p.count - i, a.count - j)
        if n <= 0 { return i >= p.count && j >= a.count }
        for t in 0..<n where norm(p[i + t]) != norm(a[j + t]) { return false }
        return true
    }

    /// map[i] = offset in Notes' AX text of editor offset i (0...count). The two texts differ only by spacing
    /// substitutions (nbsp, U+2028/9), characters Notes' view adds (list markers) or a trailing newline.
    static func offsetMap(editor p: [UInt16], ax a: [UInt16]) -> [Int]? {
        var map = [Int](repeating: 0, count: p.count + 1)
        var i = 0, j = 0
        while i < p.count {
            if j < a.count, norm(p[i]) == norm(a[j]) { map[i] = j; i += 1; j += 1; continue }
            var moved = false
            for k in 1...8 where j + k < a.count && agree(p, i, a, j + k) { j += k; moved = true; break }
            if moved { continue }
            for k in 1...3 where i + k < p.count && j < a.count && agree(p, i + k, a, j) {
                for t in 0..<k { map[i + t] = j }
                i += k; moved = true; break
            }
            if moved { continue }
            if j >= a.count { for t in i..<p.count { map[t] = a.count }; i = p.count; break }
            return nil
        }
        map[p.count] = j
        return map
    }

    /// Runs the edits (already in descending order). Returns success and the text Notes holds afterwards.
    private static func apply(_ edits: [TextEdit], to start: String, in area: AXUIElement) -> (Bool, String) {
        var cur = start
        for e in edits {
            let len = (cur as NSString).length
            guard e.range.location >= 0, NSMaxRange(e.range) <= len, select(area, e.range) else { return (false, value(of: area) ?? cur) }
            if e.range.length > 0, let picked = selectedText(of: area), picked != (cur as NSString).substring(with: e.range) {
                return (false, value(of: area) ?? cur)
            }
            guard AXUIElementSetAttributeValue(area, kAXSelectedTextAttribute as CFString, e.replacement as CFString) == .success else {
                return (false, value(of: area) ?? cur)
            }
            let expected = NotesTextDiff.apply(e, to: cur)
            guard waitForValue(area, expected) else { return (false, value(of: area) ?? cur) }
            cur = expected
        }
        return (true, cur)
    }

    // MARK: Debug

    /// `--debug-ax-edit=<note id>`: inserts a word on line 3 and deletes the last word of line 5 of THAT note through
    /// the lazy save pipeline, logging each stage (category ax-edit). Only for a throwaway test note.
    static func debugEdit(uri: String) {
        queue.async {
            guard case .ok(let st) = readState(uri: uri) else { log.notice("debug-ax-edit: state failed"); return }
            let base = st.plain
            var lines = base.components(separatedBy: "\n")
            if lines.count > 2 { lines[2] += " inserted" }
            if lines.count > 4 {
                var words = lines[4].components(separatedBy: " ")
                if words.count > 1 { words.removeLast(); lines[4] = words.joined(separator: " ") }
            }
            let target = lines.joined(separator: "\n")
            let out = write(uri: uri, basePlain: st.plain, baseMod: st.mod, baseline: base, target: target, attachments: st.attachments)
            log.notice("debug-ax-edit: result=\(String(describing: out.result), privacy: .public) attachments=\(st.attachments)")
        }
    }
}

/// Remembers the last app the user was in that is neither MacNotch nor Notes, so focus can go back there even when
/// Notes happens to be frontmost at the moment editing starts.
enum FocusTracker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pid: pid_t?
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    static var lastExternalPID: pid_t? { lock.lock(); defer { lock.unlock() }; return pid }
    @MainActor static var lastExternal: NSRunningApplication? { lastExternalPID.flatMap { NSRunningApplication(processIdentifier: $0) } }

    @MainActor static func start() {
        guard observer == nil else { return }
        func consider(_ app: NSRunningApplication?) {
            guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.bundleIdentifier != "com.apple.Notes", app.activationPolicy == .regular else { return }
            lock.lock(); pid = app.processIdentifier; lock.unlock()
        }
        consider(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { consider(app) }
        }
    }
}
