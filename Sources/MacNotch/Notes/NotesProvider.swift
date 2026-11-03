import Foundation
import os
import AppKit
import Combine

@MainActor
final class NotesProvider: ObservableObject {
    static let folderDefaultsKey = "notes.folderName"
    static let defaultFolder = "MacNotch"

    @Published private(set) var notes: [NoteItem] = []
    @Published private(set) var status: NotesStatus = .loading
    @Published private(set) var source: NotesSource = .database
    @Published var folderName: String {
        didSet {
            guard folderName != oldValue else { return }
            UserDefaults.standard.set(folderName, forKey: Self.folderDefaultsKey)
            clearCache(); cancelList()
            lastListFetch = nil
            reload()
        }
    }

    let workQueue = DispatchQueue(label: "macnotch.notes.db", qos: .utility)
    private var watcher: NotesFileWatcher?
    private var storeUUID: String?
    private var generation = 0
    private var started = false
    static let automationGrantedKey = "notes.automationGranted"
    private static let listThrottle: TimeInterval = 30
    nonisolated private static let notesBundleID = "com.apple.Notes"
    var lastListFetch: Date?
    private var listTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var listGen = 0
    private var dirty = false
    private var fdaGranted = false
    /// Set by NotchViewModel; while false, store changes only mark the list dirty.
    var isViewing = false {
        didSet { if !isViewing && oldValue { flushEditsOnCollapse() } }
    }

    /// Folder names for the picker (loaded lazily by `loadFolders()`, cached).
    @Published private(set) var availableFolders: [String] = []
    private var foldersLoadedAt: Date?
    private var foldersLoading = false
    /// The editor currently showing a note, if any (weak: owned by the detail view).
    weak var activeSession: NoteEditSession?
    private var terminateObserver: NSObjectProtocol?

    private var bodyCache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var cacheIDs: [String: Int64] = [:]
    private var cacheEpoch = 0
    private let cacheLimit = 5

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.folderDefaultsKey)
        folderName = (saved?.isEmpty == false) ? saved! : Self.defaultFolder
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSession?.flushSynchronously() }
        }
    }

    deinit {
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
        if let o = launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    func start() {
        guard !started else { reload(); return }
        started = true
        // Cheap retry path for permission changes (no polling).
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appDidBecomeActive() }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.notesBundleID else { return }
            Task { @MainActor in
                guard let self, self.status == .notesNotRunning else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)   // let Notes finish launching
                self.lastListFetch = nil
                self.reload()
            }
        }
        reload()
    }

    private func appDidBecomeActive() {
        if case .error = status { reload(); return }
        if status == .needsFullDiskAccess { reload(); return }
        if source == .appleScript {
            // Re-check Full Disk Access silently; switch to the database source if it was granted.
            workQueue.async { [weak self] in
                guard NotesDatabase.hasFullDiskAccess() else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.reload() } }
            }
        }
        if status == .needsAutomationAccess || status == .notesNotRunning { refreshIfNeeded() }
    }

    private func storeChanged() {
        if isViewing { reload() } else { dirty = true }
    }

    private func ensureWatcher() {
        if let w = watcher { w.restart(); return }
        let w = NotesFileWatcher(path: NotesDatabase.defaultPath) { [weak self] in
            Task { @MainActor in self?.storeChanged() }
        }
        w.start()
        watcher = w
    }

    private func stopWatcher() {
        watcher?.stop(); watcher = nil
    }

    func reload() {
        generation += 1
        dirty = false
        let gen = generation
        let folder = folderName
        if notes.isEmpty { status = .loading }
        workQueue.async { [weak self] in
            let outcome: Result<NotesQueryResult, NotesDBError>
            // Never touch the Notes group container unless Full Disk Access is already granted (no TCC prompt).
            if !NotesDatabase.hasFullDiskAccess() {
                outcome = .failure(.needsFullDiskAccess)
            } else {
                do { outcome = .success(try NotesDatabase.query(folderName: folder)) }
                catch let e as NotesDBError { outcome = .failure(e) }
                catch { outcome = .failure(.other(error.localizedDescription)) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(outcome, gen: gen, folder: folder) }
            }
        }
    }

    private func apply(_ outcome: Result<NotesQueryResult, NotesDBError>, gen: Int, folder: String) {
        guard gen == generation else { return }
        switch outcome {
        case .failure(.needsFullDiskAccess):
            fdaGranted = false
            stopWatcher()
            if source != .appleScript { source = .appleScript; notes = []; clearCache() }
            fallbackToAppleScript(force: false)
        case .failure(.other(let m)):
            status = .error(m)
        case .success(let r):
            fdaGranted = true
            ensureWatcher()
            if source != .database { source = .database; cancelList(); clearCache() }
            storeUUID = r.storeUUID
            if r.folderCount == 0 { notes = []; status = .folderNotFound(folder) }
            else if r.notes.isEmpty { notes = []; status = .empty }
            else { if notes != r.notes { notes = r.notes }; status = .ok }
            pruneCache()
        }
    }

    private func cancelList() {
        listTask?.cancel(); listTask = nil; listGen += 1
    }

    private func clearCache() {
        bodyCache.removeAll(); cacheOrder.removeAll(); cacheIDs.removeAll(); cacheEpoch += 1
    }

    /// Drops cached bodies whose note is no longer in the visible (unlocked) list.
    private func pruneCache() {
        let valid = Set(notes.map(\.id))
        let stale = cacheOrder.filter { !valid.contains(cacheIDs[$0] ?? -1) }
        for k in stale { bodyCache[k] = nil; cacheIDs[k] = nil }
        cacheOrder.removeAll { stale.contains($0) }
        cacheEpoch += 1
    }

    var notesIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.notesBundleID).isEmpty
    }

    // MARK: AppleScript fallback (lazy, throttled, no timers)

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

    /// Called by the UI on expand. No cost when the database source works.
    func refreshIfNeeded() {
        if source == .database {
            if dirty { reload() }
            return
        }
        fallbackToAppleScript(force: false)
    }

    private func fallbackToAppleScript(force: Bool) {
        // Decide silently whether we may talk to Notes.
        switch automationPermission() {
        case .some(false):
            automationGranted = false
            cancelList(); notes = []; clearCache(); status = .needsAutomationAccess
            return
        case .some(true):
            automationGranted = true
        case .none:
            if !automationGranted { cancelList(); notes = []; clearCache(); status = .needsAutomationAccess; return }
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
            self.listTask = nil                                     // always clear for the current token
            guard !Task.isCancelled, folder == self.folderName, self.source == .appleScript else { return }
            self.applyList(result, folder: folder)
        }
    }

    private struct ListResult { var notes: [NoteItem]; var storeUUID: String? }

    private static func fetchList(folder: String) async -> Result<ListResult, NotesScripting.ScriptError> {
        let scripting = NotesScripting.shared
        var first = await scripting.runDetailed(NotesScripting.listScript(folder: folder))
        if case .failure(let e) = first, e.code == NotesScripting.listChangedCode {
            first = await scripting.runDetailed(NotesScripting.listScript(folder: folder))   // folder changed mid-read: retry once
        }
        switch first {
        case .failure(let e): return .failure(e)
        case .success(let raw):
            struct Row { var id: String; var title: String; var secs: Double; var body: String }
            var top: [Row] = []
            for rec in raw.components(separatedBy: NotesScripting.recordSep) where !rec.isEmpty {
                let f = rec.components(separatedBy: NotesScripting.fieldSep)
                guard f.count >= 4, let secs = Double(f[2].replacingOccurrences(of: ",", with: ".")) else { continue }
                top.append(Row(id: f[0], title: f[1], secs: secs, body: f[3...].joined(separator: " ")))
            }
            var comps = DateComponents(); comps.year = 2001; comps.month = 1; comps.day = 1
            let base = Calendar.current.date(from: comps) ?? Date(timeIntervalSinceReferenceDate: 0)
            var uuid: String?
            var items: [NoteItem] = []
            for r in top {
                // id looks like x-coredata://<UUID>/ICNote/p123
                let parts = r.id.components(separatedBy: "/")
                var pk = Int64(r.id.hashValue)
                if let last = parts.last, last.hasPrefix("p"), let n = Int64(last.dropFirst()) { pk = n }
                if parts.count > 2, uuid == nil { uuid = parts[2] }
                let body = r.body
                var lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                lines = lines.filter { !$0.isEmpty }
                if !lines.isEmpty { lines.removeFirst() }   // first line is the title
                let snip = String(lines.joined(separator: " ").prefix(140))
                items.append(NoteItem(id: pk, title: r.title.isEmpty ? "New Note" : r.title,
                                      snippet: snip, modified: base.addingTimeInterval(r.secs)))
            }
            return .success(ListResult(notes: items, storeUUID: uuid))
        }
    }

    private func applyList(_ result: Result<ListResult, NotesScripting.ScriptError>, folder: String) {
        switch result {
        case .success(let r):
            automationGranted = true
            if let u = r.storeUUID { storeUUID = u }
            if r.notes.isEmpty { notes = []; status = .empty }
            else { if notes != r.notes { notes = r.notes }; status = .ok }
            pruneCache()
        case .failure(let e):
            lastListFetch = nil
            notes = []; clearCache()
            switch e.code {
            case -1743, -1744: automationGranted = false; status = .needsAutomationAccess
            case NotesScripting.timeoutCode: status = .error("Notes Didn't Respond")
            case -10004: status = .needsFullDiskAccess   // both paths blocked by privacy
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

    // MARK: AppleScript

    func uri(for note: NoteItem) -> String? {
        storeUUID.map { NotesScripting.noteURI(storeUUID: $0, pk: note.id) }
    }

    func fullBody(for note: NoteItem) async -> String? {
        // Only serve notes still present in the current (unlocked) list.
        guard notes.contains(where: { $0.id == note.id }) else { return nil }
        let key = "\(note.id)@\(note.modified.timeIntervalSinceReferenceDate)"
        if let hit = bodyCache[key] { return hit }
        guard notesIsRunning else { return nil }   // never launch Notes just to read a body
        let epoch = cacheEpoch
        // The script itself re-verifies `password protected is false` before reading plaintext.
        let script = NotesScripting.bodyScript(uri: uri(for: note), title: note.title, folder: folderName)
        guard let out = await NotesScripting.shared.run(script),
              out != "!LOCKED", out != "!NOTFOUND" else { return nil }
        // The list changed while we were reading: re-validate before caching/returning.
        guard epoch == cacheEpoch || notes.contains(where: { $0.id == note.id && $0.modified == note.modified }) else { return nil }
        bodyCache[key] = out
        cacheIDs[key] = note.id
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > cacheLimit { let k = cacheOrder.removeFirst(); bodyCache[k] = nil; cacheIDs[k] = nil }
        return out
    }

    // MARK: Folder picker

    private static let folderCacheTTL: TimeInterval = 30

    /// Lazily loads the folder names (menu or Settings picker opened). Cached for 30 s. Uses the database when
    /// Full Disk Access is granted, otherwise AppleScript, and never launches Notes.
    func loadFolders(force: Bool = false) {
        if foldersLoading { return }
        if !force, let t = foldersLoadedAt, Date().timeIntervalSince(t) < Self.folderCacheTTL { return }
        foldersLoading = true
        let useDB = NotesDatabase.hasFullDiskAccess()
        if useDB {
            workQueue.async { [weak self] in
                let names = try? NotesDatabase.folderNames()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyFolders(names) } }
            }
            return
        }
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

    func openInNotes(_ note: NoteItem) {
        NotesScripting.shared.fireAndForget(
            NotesScripting.showScript(uri: uri(for: note), title: note.title, folder: folderName))
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Watches NoteStore.sqlite and its -wal file; debounced, no timers while idle (retries back off to 30 s
/// only while a file is missing).
final class NotesFileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "macnotch.notes.watch", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private var backoff: [String: TimeInterval] = [:]
    private var retrying = Set<String>()
    private var token = 0

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path; self.onChange = onChange
    }

    func start() { queue.async { self.openAll() } }
    func restart() { queue.async { self.backoff.removeAll(); self.openAll() } }
    func stop() {
        queue.async {
            self.token += 1
            self.pending?.cancel(); self.pending = nil
            self.retrying.removeAll()
            for (_, s) in self.sources { s.cancel() }
            self.sources.removeAll()
        }
    }

    private func openAll() {
        for p in [path, path + "-wal"] where sources[p] == nil { open(p) }
    }

    private func open(_ p: String) {
        let fd = Darwin.open(p, O_EVTONLY)
        guard fd >= 0 else { scheduleRetry(p); return }
        backoff[p] = nil
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let ev = src.data
            if ev.contains(.delete) || ev.contains(.rename) {
                src.cancel()
                self.sources[p] = nil
                self.backoff[p] = nil
                self.scheduleRetry(p)
            }
            self.schedule()
        }
        src.setCancelHandler { Darwin.close(fd) }
        sources[p] = src
        src.resume()
    }

    /// Re-open a missing file with backoff 1, 2, 4 ... 30 s; stops once opened.
    private func scheduleRetry(_ p: String) {
        guard !retrying.contains(p) else { return }
        retrying.insert(p)
        let delay = min(30, backoff[p] ?? 1)
        backoff[p] = delay * 2
        let t = token
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, t == self.token else { return }
            self.retrying.remove(p)
            if self.sources[p] == nil { self.open(p) }
        }
    }

    private func schedule() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openAll()          // re-arm anything that went missing
            self.onChange()
        }
        pending = w
        queue.asyncAfter(deadline: .now() + 1.0, execute: w)
    }
}
