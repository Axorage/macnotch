import Foundation
import os
import AppKit
import Combine

struct NoteItem: Identifiable, Hashable {
    let id: String         // Notes scripting id (x-coredata://...)
    let title: String
    let snippet: String
    let modified: Date
}

enum NotesStatus: Equatable {
    case loading, ok, needsAutomationAccess, notesNotRunning, folderNotFound(String), empty, error(String)
}

/// Lists the notes of one Notes folder through AppleScript (Automation permission only) and opens a note in Notes.
@MainActor
final class NotesProvider: ObservableObject {
    static let folderDefaultsKey = "notes.folderName"
    static let defaultFolder = "MacNotch"
    static let automationGrantedKey = "notes.automationGranted"
    private static let listThrottle: TimeInterval = 30
    private static let maxNotes = 500
    nonisolated private static let notesBundleID = "com.apple.Notes"

    @Published private(set) var notes: [NoteItem] = []
    @Published private(set) var status: NotesStatus = .loading
    @Published var folderName: String {
        didSet {
            guard folderName != oldValue else { return }
            UserDefaults.standard.set(folderName, forKey: Self.folderDefaultsKey)
            cancelList()
            notes = []
            lastListFetch = nil
            reload()
        }
    }

    /// Folder names for the picker (loaded lazily by `loadFolders()`, cached).
    @Published private(set) var availableFolders: [String] = []
    private var foldersLoadedAt: Date?
    private var foldersLoading = false

    private var started = false
    private var lastListFetch: Date?
    private var listTask: Task<Void, Never>?
    private var listGen = 0
    private var activeObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.folderDefaultsKey)
        folderName = (saved?.isEmpty == false) ? saved! : Self.defaultFolder
    }

    deinit {
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    func start() {
        guard !started else { return }
        started = true
        // Cheap retry path for permission changes (no polling).
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if case .error = self.status { self.reload(); return }
                if self.status == .needsAutomationAccess || self.status == .notesNotRunning { self.refreshIfNeeded() }
            }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.notesBundleID else { return }
            Task { @MainActor in
                guard let self, self.status == .notesNotRunning else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // let Notes finish launching
                self.reload()
            }
        }
    }

    private func cancelList() {
        listTask?.cancel(); listTask = nil; listGen += 1
    }

    var notesIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.notesBundleID).isEmpty
    }

    // MARK: Listing (lazy, throttled, no timers)

    var automationGranted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.automationGrantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.automationGrantedKey) }
    }

    /// Silent permission check; never prompts. nil = unknown (e.g. Notes not running).
    private func automationPermission() -> Bool? {
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.notesBundleID)
        guard let desc = target.aeDesc else { return nil }
        let status = AEDeterminePermissionToAutomateTarget(
            desc, typeWildCard, typeWildCard, false)
        switch Int(status) {
        case 0: return true
        case -1743, -1744: return false   // denied / would require consent
        default: return nil               // procNotFound (-600) etc.
        }
    }
    /// Forced fetch (folder change, retry, after a permission change).
    func reload() { lastListFetch = nil; fetch(force: true) }

    /// Called by the UI on expand: fetches at most every 30 s.
    func refreshIfNeeded() { fetch(force: false) }

    private func fetch(force: Bool) {
        // Decide silently whether we may talk to Notes.
        switch automationPermission() {
        case .some(false):
            automationGranted = false
            cancelList(); notes = []; status = .needsAutomationAccess
            return
        case .some(true):
            automationGranted = true
        case .none:
            if !automationGranted { cancelList(); notes = []; status = .needsAutomationAccess; return }
        }
        // Never auto-launch Notes: keep the cached list, or show an "open Notes" state.
        if !notesIsRunning {
            cancelList()
            if notes.isEmpty || status == .loading { notes = []; status = .notesNotRunning }
            return
        }
        let hasResult: Bool = { switch status { case .ok, .empty, .folderNotFound: return true; default: return false } }()
        if !force, hasResult, let t = lastListFetch, Date().timeIntervalSince(t) < Self.listThrottle { return }
        if listTask != nil, !force { return }   // already in flight
        if !force, NotesScripting.shared.isBusy {
            // A script (possibly hung) is still executing; don't pile another list fetch behind it.
            if notes.isEmpty { status = .error("Notes Didn't Respond") }
            return
        }
        cancelList()
        if notes.isEmpty && !hasResult { status = .loading }
        let folder = folderName
        lastListFetch = Date()
        let token = listGen
        listTask = Task { [weak self] in
            let result = await Self.fetchList(folder: folder)
            guard let self, token == self.listGen else { return }   // superseded
            self.listTask = nil
            guard !Task.isCancelled, folder == self.folderName else { return }
            self.applyList(result, folder: folder)
        }
    }

    private static func fetchList(folder: String) async -> Result<[NoteItem], NotesScripting.ScriptError> {
        let scripting = NotesScripting.shared
        var first = await scripting.runDetailed(NotesScripting.listScript(folder: folder))
        if case .failure(let e) = first, e.code == NotesScripting.listChangedCode {
            first = await scripting.runDetailed(NotesScripting.listScript(folder: folder))   // folder changed mid-read: retry once
        }
        switch first {
        case .failure(let e): return .failure(e)
        case .success(let raw):
            var comps = DateComponents(); comps.year = 2001; comps.month = 1; comps.day = 1
            let base = Calendar.current.date(from: comps) ?? Date(timeIntervalSinceReferenceDate: 0)
            var items: [NoteItem] = []
            for rec in raw.components(separatedBy: NotesScripting.recordSep) where !rec.isEmpty {
                let f = rec.components(separatedBy: NotesScripting.fieldSep)
                guard f.count >= 4, let secs = Double(f[2].replacingOccurrences(of: ",", with: ".")) else { continue }
                var lines = f[3...].joined(separator: " ").split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !lines.isEmpty { lines.removeFirst() }   // first line is the title
                items.append(NoteItem(id: f[0], title: f[1].isEmpty ? "New Note" : f[1],
                                      snippet: String(lines.joined(separator: " ").prefix(140)),
                                      modified: base.addingTimeInterval(secs)))
            }
            items.sort { $0.modified > $1.modified }
            return .success(Array(items.prefix(maxNotes)))
        }
    }

    private func applyList(_ result: Result<[NoteItem], NotesScripting.ScriptError>, folder: String) {
        switch result {
        case .success(let items):
            automationGranted = true
            Self.log.notice("list loaded: \(items.count) notes")
            if items.isEmpty { notes = []; status = .empty }
            else { if notes != items { notes = items }; status = .ok }
        case .failure(let e):
            lastListFetch = nil
            notes = []
            switch e.code {
            case -1743, -1744: automationGranted = false; status = .needsAutomationAccess
            case NotesScripting.timeoutCode: status = .error("Notes Didn't Respond")
            case NotesScripting.listChangedCode: status = .error("Notes Changed While Reading")
            case -1728, -1719: status = .folderNotFound(folder)
            default:
                status = e.message.contains("Can\u{2019}t get folder") || e.message.contains("Can't get folder")
                    ? .folderNotFound(folder) : .error(e.message)
            }
        }
    }

    /// Triggers the system Automation prompt (trivial Notes script), then reloads.
    func requestAutomationAccess() async {
        // Explicitly ask TCC (blocks until the user answers) off the main thread. This is what
        // registers MacNotch in Privacy & Security > Automation. Notes must be running for it.
        if !notesIsRunning { await launchNotesInBackground() }
        let status = await Task.detached(priority: .userInitiated) { () -> Int in
            let target = NSAppleEventDescriptor(bundleIdentifier: NotesProvider.notesBundleID)
            guard let desc = target.aeDesc else { return -1 }
            return Int(AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true))
        }.value
        NotesProvider.log.notice("AEDeterminePermissionToAutomateTarget(ask) -> \(status)")
        let r = await NotesScripting.shared.runDetailed("tell application \"Notes\" to return name")
        switch r {
        case .success: automationGranted = true
        case .failure(let e): if e.code == -1743 { automationGranted = false }
        }
        lastListFetch = nil
        reload()
    }

    /// Creates `folderName` in the default Notes account (user-initiated), then reloads.
    func createFolder() async {
        let name = NotesScripting.escape(folderName)
        let r = await NotesScripting.shared.runDetailed("""
            tell application "Notes"
                tell default account to make new folder with properties {name:"\(name)"}
            end tell
            """)
        if case .failure(let e) = r {
            if e.code == -1743 { automationGranted = false; status = .needsAutomationAccess }
            else if e.code == NotesScripting.timeoutCode { status = .error("Notes Didn't Respond") }
            else { status = .error(e.message) }
            return
        }
        automationGranted = true
        lastListFetch = nil
        reload()
    }

    private func launchNotesInBackground() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.notesBundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        cfg.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        for _ in 0..<20 where !notesIsRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    static let log = Logger(subsystem: "com.eortizd.macnotch", category: "notes")

    /// Silent Automation status for Notes (never prompts). nil = not determined yet (never asked).
    /// Returns nil also when Notes isn't running (the check needs a running target).
    nonisolated static func automationStatusSilently() -> Bool? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID).isEmpty else { return nil }
        let target = NSAppleEventDescriptor(bundleIdentifier: notesBundleID)
        guard let desc = target.aeDesc else { return nil }
        let rc = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        switch Int(rc) {
        case 0: return true
        case -1744: return nil          // errAEEventWouldRequireUserConsent: not asked yet
        default: return false           // -1743 denied (or -600 not running)
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
    // MARK: Folder picker

    private static let folderCacheTTL: TimeInterval = 30

    /// Lazily loads the folder names (Settings picker opened). Cached for 30 s; never launches Notes.
    func loadFolders(force: Bool = false) {
        if foldersLoading { return }
        if !force, let t = foldersLoadedAt, Date().timeIntervalSince(t) < Self.folderCacheTTL { return }
        foldersLoading = true
        guard notesIsRunning, automationPermission() != false else { foldersLoading = false; return }
        Task { [weak self] in
            let r = await NotesScripting.shared.runDetailed(NotesScripting.folderNamesScript)
            var names: [String]?
            if case .success(let raw) = r {
                names = Array(Set(raw.components(separatedBy: NotesScripting.recordSep).filter { !$0.isEmpty }))
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            self?.applyFolders(names)
        }
    }

    private func applyFolders(_ names: [String]?) {
        foldersLoading = false
        guard let names else { return }
        foldersLoadedAt = Date()
        if names != availableFolders { availableFolders = names }
    }

    // MARK: Open in Notes

    /// Shows the note in Notes and brings Notes to the front.
    func openInNotes(_ note: NoteItem) {
        NotesScripting.shared.fireAndForget(NotesScripting.showScript(id: note.id))
        // Fallback: ask LaunchServices to activate Notes (it is already running, so this only raises it).
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.notesBundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
    }
}
