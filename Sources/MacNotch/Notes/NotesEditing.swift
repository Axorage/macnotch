import Foundation
import AppKit
import ApplicationServices
import os

// MARK: Provider: reading / writing a single note for the inline editor

enum EditProbe {
    case editable(NSAttributedString, mod: Int, html: String, plain: String)
    case rich(display: String?), tooLong, locked, unavailable
}

enum SaveOutcome {
    case saved(mod: Int)
    case conflict(currentMod: Int)
    case locked, rich
    case failed(String)
}

extension NotesProvider {
    /// Live read of the note (never launches Notes). Decides whether it is safe to edit as plain text.
    func probeForEdit(_ note: NoteItem) async -> EditProbe {
        guard notesIsRunning, let uri = uri(for: note) else { return .unavailable }
        let r = await NotesScripting.shared.runDetailed(NotesScripting.editProbeScript(uri: uri))
        guard case .success(let out) = r else { return .unavailable }
        if out == "!LOCKED" { return .locked }
        let f = out.components(separatedBy: NotesScripting.fieldSep)
        guard f.count >= 4, let attachments = Int(f[0]), let mod = Int(f[1]) else { return .unavailable }
        let html = f[3...].joined(separator: NotesScripting.fieldSep)
        if attachments > 0 {
            Log.notes.notice("read-only: \(attachments) attachment(s)")
            return .rich(display: nil)
        }
        if html.count > NoteHTML.maxEditableLength { return .tooLong }
        guard let doc = NoteHTML.makeEditable(html: html, plaintext: f[2]) else {
            Log.notes.notice("read-only: \(NoteHTML.lastFailure, privacy: .public)")
            return .rich(display: NoteHTML.readOnlyDisplay(html: html))
        }
        return .editable(doc, mod: mod, html: html, plain: f[2])
    }

    func currentModification(of note: NoteItem) async -> Int? {
        guard notesIsRunning, let uri = uri(for: note) else { return nil }
        if case .success(let s) = await NotesScripting.shared.runDetailed(NotesScripting.modProbeScript(uri: uri)) {
            return Int(s)
        }
        return nil
    }

    func save(_ note: NoteItem, expectedMod: Int, html: String) async -> SaveOutcome {
        guard notesIsRunning else { return .failed("Open Notes to save.") }
        guard let uri = uri(for: note) else { return .failed("Couldn\u{2019}t find this note.") }
        return Self.interpretSave(
            await NotesScripting.shared.runDetailed(NotesScripting.saveScript(uri: uri, expectedMod: expectedMod, html: html)))
    }

    /// Blocking variant used only while the app is quitting.
    func saveBlocking(_ note: NoteItem, expectedMod: Int, html: String) -> SaveOutcome {
        guard notesIsRunning, let uri = uri(for: note) else { return .failed("Notes unavailable") }
        return Self.interpretSave(
            NotesScripting.shared.runBlocking(NotesScripting.saveScript(uri: uri, expectedMod: expectedMod, html: html)))
    }

    private static func interpretSave(_ r: Result<String, NotesScripting.ScriptError>) -> SaveOutcome {
        switch r {
        case .failure(let e):
            if e.code == -1743 { return .failed("Allow MacNotch to control Notes in Settings.") }
            if e.code == NotesScripting.timeoutCode { return .failed("Notes didn\u{2019}t respond.") }
            return .failed("Couldn\u{2019}t save.")
        case .success(let s):
            let f = s.components(separatedBy: NotesScripting.fieldSep)
            switch f.first {
            case "OK": return .saved(mod: Int(f.count > 1 ? f[1] : "") ?? 0)
            case "!CONFLICT": return .conflict(currentMod: Int(f.count > 1 ? f[1] : "") ?? 0)
            case "!LOCKED": return .locked
            case "!RICH": return .rich
            default: return .failed("Couldn\u{2019}t save.")
            }
        }
    }

    /// After a successful save: refresh the list (title and snippet may have changed).
    func refreshAfterEdit() {
        lastListFetch = nil
        if source == .database { reload() } else { refreshIfNeeded() }
    }

    /// The island is collapsing: save whatever is pending.
    func flushEditsOnCollapse() {
        guard let s = activeSession else { return }
        Log.notes.notice("save: flush (collapse/resignKey) dirty=\(s.hasUnsavedChanges)")
        Task { _ = await s.saveNow() }
    }

    // MARK: Open in Notes at a line

    static let axHintPendingKey = "notes.axHintPending"
    static let axHintDismissedKey = "notes.axHintDismissed"

    /// Shows the note and activates Notes; when Accessibility is allowed and an offset is given, puts the
    /// insertion point at that UTF-16 offset of the note text. `expectedPrefix` guards against moving the cursor
    /// in a different note while Notes is still switching.
    func openInNotes(_ note: NoteItem, caretOffset: Int?, expectedPrefix: String) async {
        _ = await NotesScripting.shared.runDetailed(
            NotesScripting.showScript(uri: uri(for: note), title: note.title, folder: folderName))
        guard let offset = caretOffset else { return }
        guard AXIsProcessTrusted() else {
            if !UserDefaults.standard.bool(forKey: Self.axHintDismissedKey) {
                UserDefaults.standard.set(true, forKey: Self.axHintPendingKey)
            }
            return
        }
        Task.detached(priority: .userInitiated) {
            let ok = await NotesLineJump.place(offset: offset, expectedPrefix: expectedPrefix)
            Logger(subsystem: "com.eortizd.macnotch", category: "notes").notice("line jump ok=\(ok)")
        }
    }

    /// User clicked "Open Settings" on the hint: this is the only place the Accessibility prompt is shown.
    static func requestAccessibility() {
        UserDefaults.standard.set(true, forKey: axHintDismissedKey)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: Accessibility: move the insertion point in Notes

enum NotesLineJump {
    /// Retries for about a second while Notes loads the note.
    static func place(offset: Int, expectedPrefix: String) async -> Bool {
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 75_000_000)
            if tryPlace(offset: offset, expectedPrefix: expectedPrefix) { return true }
        }
        return false
    }

    static func tryPlace(offset: Int, expectedPrefix: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        guard let window = element(root, kAXFocusedWindowAttribute) ?? element(root, kAXMainWindowAttribute),
              let area = findTextArea(in: window) else { return false }
        // The right note must be on screen: its text starts with the line we are about to jump into.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(area, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, !expectedPrefix.isEmpty, text.hasPrefix(expectedPrefix),
              offset <= (text as NSString).length else { return false }
        _ = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var range = CFRange(location: offset, length: 0)
        guard let v = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, v) == .success else { return false }
        var back: CFTypeRef?
        guard AXUIElementCopyAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, &back) == .success,
              let bv = back, CFGetTypeID(bv) == AXValueGetTypeID() else { return false }
        var got = CFRange()
        AXValueGetValue(bv as! AXValue, .cfRange, &got)
        return got.location == offset
    }

    private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Breadth-first search for the note body (AXTextArea), capped in depth and node count.
    private static func findTextArea(in root: AXUIElement) -> AXUIElement? {
        var level = [root]
        var visited = 0
        for _ in 0..<10 {
            var next: [AXUIElement] = []
            for el in level {
                visited += 1
                if visited > 600 { return nil }
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
                   (role as? String) == kAXTextAreaRole { return el }
                var kids: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
                   let arr = kids as? [AXUIElement] { next += arr }
            }
            if next.isEmpty { return nil }
            level = next
        }
        return nil
    }
}

// MARK: Editing session (one per open note detail)

@MainActor
final class NoteEditSession: ObservableObject {
    enum Mode: Equatable {
        case loading, editable, unavailable
        case readOnly(ReadOnlyReason)
    }
    enum ReadOnlyReason: Equatable { case rich, tooLong, locked }
    enum SaveState: Equatable { case idle, saving, saved, failed(String), conflict }

    @Published private(set) var mode: Mode = .loading
    @Published private(set) var saveState: SaveState = .idle
    @Published private(set) var liveTitle: String
    /// Bumped when the editor text must be replaced from outside (initial load, Reload).
    @Published private(set) var reloadToken = 0

    let note: NoteItem
    private unowned let notes: NotesProvider
    private(set) var text = ""
    /// Initial / reloaded content for the editor (list markers and styling included).
    private(set) var attributed = NSAttributedString()
    /// Latest editor content (what the next save serializes).
    private var current = NSAttributedString()
    /// True once the user changed something in this session (shows "Revert to Original").
    @Published private(set) var hasEdited = false
    var selection = NSRange(location: 0, length: 0)
    /// Original body HTML, kept in memory for the session.
    private(set) var preEditHTML = ""
    /// Text with list markers for the read-only view (nil: fall back to Notes' plain text).
    private(set) var readOnlyDisplay: String?

    private var preEditPlain = ""
    private var baseMod = 0
    private var remoteMod = 0
    private var dirty = false
    private var saving = false
    private var debounce: Task<Void, Never>?
    private var fade: Task<Void, Never>?

    static let autosaveDelay: UInt64 = 1_500_000_000

    init(note: NoteItem, notes: NotesProvider) {
        self.note = note
        self.notes = notes
        liveTitle = note.title
    }

    var hasUnsavedChanges: Bool { dirty || saving }

    func load() async {
        notes.activeSession = self
        mode = .loading
        // A restored note can open before the list (needed to resolve the note's URI) has loaded: wait for it.
        var probe = await notes.probeForEdit(note)
        var waited = 0
        while case .unavailable = probe, notes.status == .loading, waited < 100 {
            try? await Task.sleep(nanoseconds: 100_000_000); waited += 1
            probe = await notes.probeForEdit(note)
        }
        switch probe {
        case .editable(let d, let mod, let html, let plain):
            baseMod = mod; preEditHTML = html; preEditPlain = plain
            attributed = d; current = d
            text = d.string; dirty = false; saveState = .idle; hasEdited = false
            liveTitle = NoteHTML.title(of: d) ?? note.title
            reloadToken += 1
            mode = .editable
        case .rich(let display): readOnlyDisplay = display; mode = .readOnly(.rich)
        case .tooLong: mode = .readOnly(.tooLong)
        case .locked: mode = .readOnly(.locked)
        case .unavailable: mode = .unavailable
        }
    }

    // MARK: editing

    /// The editor content changed (text or formatting).
    func contentChanged(_ new: NSAttributedString) {
        guard mode == .editable else { return }
        current = new
        text = new.string
        dirty = true
        hasEdited = true
        liveTitle = NoteHTML.title(of: new) ?? note.title
        if saveState == .saved || saveState == .saving { saveState = .idle }
        if saveState == .conflict { return }
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            _ = await self?.saveNow()
        }
    }

    /// Saves pending changes. Returns true when nothing unsaved remains.
    @discardableResult
    func saveNow() async -> Bool {
        debounce?.cancel(); debounce = nil
        while saving { try? await Task.sleep(nanoseconds: 40_000_000) }
        guard mode == .editable else { return true }
        if saveState == .conflict { return !dirty }
        guard dirty else { return true }
        saving = true
        saveState = .saving
        fade?.cancel()
        let snapshot = current
        let html = NoteHTML.serialize(snapshot)
        let outcome = await notes.save(note, expectedMod: baseMod, html: html)
        saving = false
        apply(outcome, snapshot: snapshot)
        return !dirty
    }

    private func apply(_ outcome: SaveOutcome, snapshot: NSAttributedString) {
        switch outcome {
        case .saved(let mod):
            baseMod = mod
            if current === snapshot { dirty = false } else { scheduleAutosave() }
            saveState = .saved
            fade = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, self.saveState == .saved else { return }
                self.saveState = .idle
            }
            notes.refreshAfterEdit()
        case .conflict(let current):
            remoteMod = current
            saveState = .conflict
        case .locked: mode = .readOnly(.locked); saveState = .idle
        case .rich: mode = .readOnly(.rich); saveState = .idle
        case .failed(let m): saveState = .failed(m)
        }
    }

    /// Esc: save, and report whether it is safe to leave (nothing unsaved remains).
    func finish() async -> Bool {
        for _ in 0..<3 {
            if await saveNow() { return true }
            if case .conflict = saveState { return false }
            if case .failed = saveState { return false }
        }
        return !dirty
    }

    /// Retry after a failed save.
    func retry() { Task { _ = await saveNow() } }

    // MARK: conflict

    func reloadFromNotes() {
        Task { await load() }
    }

    /// "Keep Editing": keep local text and accept overwriting the newer version in Notes on the next save.
    func keepEditing() {
        baseMod = remoteMod
        saveState = .idle
        if dirty { scheduleAutosave() }
    }

    // MARK: revert

    /// Writes the body as it was when editing began (with the same conflict check as any save).
    func revertToOriginal() {
        guard mode == .editable, !preEditHTML.isEmpty else { return }
        Task { await performRevert() }
    }

    func performRevert() async {
        debounce?.cancel(); debounce = nil
        while saving { try? await Task.sleep(nanoseconds: 40_000_000) }
        guard mode == .editable else { return }
        saving = true
        saveState = .saving
        fade?.cancel()
        let outcome = await notes.save(note, expectedMod: baseMod, html: preEditHTML)
        saving = false
        switch outcome {
        case .saved(let mod):
            baseMod = mod
            if let a = NoteHTML.makeEditable(html: preEditHTML, plaintext: preEditPlain) {
                attributed = a; current = a; text = a.string
                liveTitle = NoteHTML.title(of: a) ?? note.title
                reloadToken += 1
            }
            dirty = false; hasEdited = false
            saveState = .saved
            fade = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, self.saveState == .saved else { return }
                self.saveState = .idle
            }
            notes.refreshAfterEdit()
        default:
            apply(outcome, snapshot: current)
        }
    }

    // MARK: drafts

    /// Unsaved text to keep when the detail goes away without a successful save.
    func draft() -> NoteDraft? {
        guard mode == .editable, dirty else { return nil }
        return NoteDraft(text: text, attributed: current, conflict: saveState == .conflict, caret: selection.location)
    }

    /// Re-apply text that could not be saved last time. A conflict stays a conflict: the user chooses.
    func restore(draft d: NoteDraft) {
        guard mode == .editable else { return }
        text = d.text
        attributed = d.attributed; current = d.attributed
        dirty = true; hasEdited = true
        liveTitle = NoteHTML.title(of: d.attributed) ?? note.title
        reloadToken += 1
        if d.conflict { remoteMod = baseMod &+ 1; saveState = .conflict } else { scheduleAutosave() }
        Log.notes.notice("draft restored conflict=\(d.conflict)")
    }

    // MARK: Edit in Notes

    /// Saves, then opens the note in Notes with the caret on the line being edited. False = stayed (unsaved
    /// changes could not be saved: conflict or error is shown inline).
    func editInNotes() async -> Bool {
        var offset: Int?
        var prefix = ""
        if mode == .editable {
            guard await saveNow() else { return false }
            let ns = text as NSString
            let loc = min(selection.location, ns.length)
            offset = ns.lineRange(for: NSRange(location: loc, length: 0)).location
            prefix = String(ns.substring(to: min(ns.length, 40)).prefix { $0 != "\n" })
        }
        await notes.openInNotes(note, caretOffset: offset, expectedPrefix: prefix)
        return true
    }

    // MARK: quitting

    /// Called while the app terminates: no async, so write synchronously.
    func flushSynchronously() {
        guard mode == .editable, dirty, !saving, saveState != .conflict else { return }
        let html = NoteHTML.serialize(current)
        if case .saved(let mod) = notes.saveBlocking(note, expectedMod: baseMod, html: html) {
            baseMod = mod; dirty = false
        }
    }
}
