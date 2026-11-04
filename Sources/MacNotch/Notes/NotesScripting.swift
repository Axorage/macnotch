import Foundation
import AppKit

/// AppleScript helpers; all execution happens on one serial background queue.
final class NotesScripting: @unchecked Sendable {
    static let shared = NotesScripting()
    private let queue = DispatchQueue(label: "macnotch.notes.applescript", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0

    /// True while any script is queued or executing (a hung script keeps this true).
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return pending > 0 }
    private func adjust(_ d: Int) { lock.lock(); pending += d; lock.unlock() }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func noteURI(storeUUID: String, pk: Int64) -> String {
        "x-coredata://\(storeUUID)/ICNote/p\(pk)"
    }

    static let timeoutCode = -1712
    static let deadline: TimeInterval = 10

    /// Returns string result, or nil on error / timeout / nil descriptor.
    func run(_ source: String) async -> String? {
        if case .success(let s) = await runDetailed(source) { return s }
        return nil
    }

    struct ScriptError: Error, Equatable { let code: Int; let message: String }

    /// Wraps a script body (containing its own `tell application "Notes"`) in an 8 s AppleScript timeout.
    static func withTimeout(_ body: String) -> String {
        "with timeout of 8 seconds\n\(body)\nend timeout"
    }

    /// Runs a script with an AppleScript timeout (8 s) plus a Swift-side deadline (10 s). A late reply is ignored.
    /// Error numbers are preserved (-1743 not permitted, -1728/-1719 can't get, -1712 timeout).
    func runDetailed(_ source: String) async -> Result<String, ScriptError> {
        await withCheckedContinuation { cont in
            let once = OnceBox(cont)
            adjust(1)
            queue.async {
                defer { self.adjust(-1) }
                var err: NSDictionary?
                let out = NSAppleScript(source: Self.withTimeout(source))?.executeAndReturnError(&err)
                if let err {
                    let code = (err["NSAppleScriptErrorNumber"] as? Int) ?? -1
                    let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "AppleScript error"
                    once.resume(.failure(ScriptError(code: code, message: msg)))
                } else {
                    once.resume(.success(out?.stringValue ?? ""))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.deadline) {
                once.resume(.failure(ScriptError(code: Self.timeoutCode, message: "Notes Didn't Respond")))
            }
        }
    }

    private final class OnceBox: @unchecked Sendable {
        private var cont: CheckedContinuation<Result<String, ScriptError>, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<Result<String, ScriptError>, Never>) { cont = c }
        func resume(_ r: Result<String, ScriptError>) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: r)
        }
    }

    // MARK: Folder listing (AppleScript fallback)

    static let fieldSep = "\u{1F}", recordSep = "\u{1E}"

    static let listChangedCode = -2700

    /// Batch-reads id/modified/locked (3 Apple events, cheap), fails with -2700 if their counts disagree (the
    /// folder changed mid-read; the caller retries). Locked notes are dropped up front. For each displayed row the
    /// note is re-fetched by id, `password protected is false` is re-confirmed in that same iteration, and the
    /// title and plaintext are read only then, so a misaligned index can never leak a locked note's title or body.
    static func listScript(folder: String, limit: Int = 50) -> String {
        """
        tell application "Notes"
            set fol to first folder whose name is "\(escape(folder))"
            set epoch to current date
            set day of epoch to 1
            set month of epoch to January
            set year of epoch to 2001
            set time of epoch to 0
            set fs to character id 31
            set rs to character id 30
            set ids to id of every note of fol
            set mds to modification date of every note of fol
            set lks to password protected of every note of fol
            set n to count of ids
            if (count of mds) is not n or (count of lks) is not n then error "list changed" number \(listChangedCode)
            if n is 0 then return ""
            set used to {}
            repeat with k from 1 to n
                set end of used to ((item k of lks) is not false)
            end repeat
            set out to ""
            set emitted to 0
            repeat while emitted < \(limit)
                set best to 0
                repeat with i from 1 to n
                    if not (item i of used) then
                        if best is 0 then
                            set best to i
                        else if (item i of mds) > (item best of mds) then
                            set best to i
                        end if
                    end if
                end repeat
                if best is 0 then exit repeat
                set item best of used to true
                try
                    set cur to note id (item best of ids)
                    if (password protected of cur) is false then
                        set nm to name of cur
                        set t to plaintext of cur
                        if (length of t) > 120 then set t to text 1 thru 120 of t
                        \(secondsTextSnippet(of: "(item best of mds) - epoch", into: "mdText"))
                        set out to out & (item best of ids) & fs & nm & fs & mdText & fs & t & rs
                        set emitted to emitted + 1
                    end if
                end try
            end repeat
            return out
        end tell
        """
    }

    /// Synchronous run on the calling thread (only for app termination).
    func runBlocking(_ source: String) -> Result<String, ScriptError> {
        var err: NSDictionary?
        let out = NSAppleScript(source: Self.withTimeout(source))?.executeAndReturnError(&err)
        if let err {
            return .failure(ScriptError(code: (err["NSAppleScriptErrorNumber"] as? Int) ?? -1,
                                        message: (err["NSAppleScriptErrorMessage"] as? String) ?? "AppleScript error"))
        }
        return .success(out?.stringValue ?? "")
    }

    func fireAndForget(_ source: String) {
        adjust(1)
        queue.async {
            defer { self.adjust(-1) }
            var err: NSDictionary?
            _ = NSAppleScript(source: Self.withTimeout(source))?.executeAndReturnError(&err)
        }
    }

    /// Script returning plaintext, or "" sentinel prefix "!LOCKED" when protected.
    static func bodyScript(uri: String?, title: String, folder: String) -> String {
        let t = escape(title), f = escape(folder)
        let byName = """
        repeat with fl in (folders whose name is "\(f)")
            set cands to (notes of fl whose name is "\(t)" and password protected is false)
            if (count of cands) > 0 then return plaintext of (item 1 of cands)
        end repeat
        return "!NOTFOUND"
        """
        if let uri {
            return """
            tell application "Notes"
                try
                    set n to note id "\(escape(uri))"
                    if password protected of n then return "!LOCKED"
                    return plaintext of n
                end try
                \(byName)
            end tell
            """
        }
        return "tell application \"Notes\"\n\(byName)\nend tell"
    }

    static func showScript(uri: String?, title: String, folder: String) -> String {
        let t = escape(title), f = escape(folder)
        let byName = """
        repeat with fl in (folders whose name is "\(f)")
            set cands to (notes of fl whose name is "\(t)" and password protected is false)
            if (count of cands) > 0 then
                show (item 1 of cands)
                exit repeat
            end if
        end repeat
        """
        if let uri {
            return """
            tell application "Notes"
                try
                    set n to note id "\(escape(uri))"
                    if password protected of n then error "locked"
                    show n
                on error
                    \(byName)
                end try
                activate
            end tell
            """
        }
        return "tell application \"Notes\"\n\(byName)\nactivate\nend tell"
    }

    // MARK: Folder names (AppleScript fallback)

    /// Names of every folder, RS-separated. "Recently Deleted" is dropped (Notes exposes no folder type).
    static let folderNamesScript = """
        tell application "Notes"
            set rs to character id 30
            set out to ""
            repeat with f in every folder
                try
                    set nm to name of f
                    if nm is not "Recently Deleted" then set out to out & nm & rs
                end try
            end repeat
            return out
        end tell
        """

    // MARK: Inline editing

    /// AppleScript prints large reals in exponent form ("8.154129E+8", losing digits) and its integers are only
    /// 30-bit, so whole seconds are turned into text digit by digit.
    static func secondsTextSnippet(of value: String, into name: String) -> String {
        """
        set tv to (\(value)) div 1
        set \(name) to ""
        repeat while tv > 0
            set dd to (tv mod 10) div 1
            set \(name) to ((dd as integer) as text) & \(name)
            set tv to tv div 10
        end repeat
        if \(name) is "" then set \(name) to "0"
        """
    }

    private static let epochSnippet = """
        set epoch to current date
        set day of epoch to 1
        set month of epoch to January
        set year of epoch to 2001
        set time of epoch to 0
        """

    /// Fields (FS-separated): LOCKED | attachments, modification seconds, plaintext, body (HTML, last).
    static func editProbeScript(uri: String) -> String {
        """
        tell application "Notes"
            set n to note id "\(escape(uri))"
            if (password protected of n) is not false then return "!LOCKED"
            \(epochSnippet)
            set fs to character id 31
            set ac to count of attachments of n
            \(secondsTextSnippet(of: "(modification date of n) - epoch", into: "mdText"))
            set pt to plaintext of n
            return (ac as text) & fs & mdText & fs & pt & fs & (body of n)
        end tell
        """
    }

    /// Cheap check used for conflict handling: "LOCKED", or the modification seconds.
    static func modProbeScript(uri: String) -> String {
        """
        tell application "Notes"
            set n to note id "\(escape(uri))"
            if (password protected of n) is not false then return "!LOCKED"
            \(epochSnippet)
            \(secondsTextSnippet(of: "(modification date of n) - epoch", into: "mdText"))
            return mdText
        end tell
        """
    }

    /// Writes the body only if the note is unlocked, has no attachments and still has the modification date
    /// seen when editing began (the check and the write happen in one script).
    /// Returns "OK<FS>newMod", "!CONFLICT<FS>currentMod", "!LOCKED" or "!RICH".
    static func saveScript(uri: String, expectedMod: Int, html: String) -> String {
        """
        tell application "Notes"
            set n to note id "\(escape(uri))"
            if (password protected of n) is not false then return "!LOCKED"
            \(epochSnippet)
            set fs to character id 31
            set md to (modification date of n) - epoch
            if md is not \(expectedMod) then
                \(secondsTextSnippet(of: "md", into: "mdText"))
                return "!CONFLICT" & fs & mdText
            end if
            if (count of attachments of n) > 0 then return "!RICH"
            set body of n to "\(escape(html))"
            \(secondsTextSnippet(of: "(modification date of n) - epoch", into: "mdText"))
            return "OK" & fs & mdText
        end tell
        """
    }

    // MARK: Accessibility-backed editing helpers

    /// Selects the note in Notes' window WITHOUT activating Notes (the AX editor needs it on screen).
    static func showInBackgroundScript(uri: String) -> String {
        """
        tell application "Notes"
            set n to note id "\(escape(uri))"
            if (password protected of n) is not false then return "!LOCKED"
            show n
            return "OK"
        end tell
        """
    }

    /// Id of the note Notes currently has selected ("" when none / unreadable).
    static let selectedNoteIDScript = """
        tell application "Notes"
            try
                return id of item 1 of (get selection)
            on error
                return ""
            end try
        end tell
        """

    /// Read-only state of a note (scripting never brings Notes forward): "!LOCKED" or
    /// attachment count, modification seconds, plaintext (FS-separated, plaintext last).
    static func lazyStateScript(uri: String) -> String {
        """
        tell application "Notes"
            set n to note id "\(escape(uri))"
            if (password protected of n) is not false then return "!LOCKED"
            \(epochSnippet)
            set fs to character id 31
            \(secondsTextSnippet(of: "(modification date of n) - epoch", into: "mdText"))
            return ((count of attachments of n) as text) & fs & mdText & fs & (plaintext of n)
        end tell
        """
    }

    /// Fields (FS-separated): LOCKED | attachment count, plaintext. Used to confirm an AX write reached the note model.
    static func verifyScript(uri: String) -> String {
        """
        tell application "Notes"
            set n to note id "\(escape(uri))"
            if (password protected of n) is not false then return "!LOCKED"
            set fs to character id 31
            return ((count of attachments of n) as text) & fs & (plaintext of n)
        end tell
        """
    }
}
