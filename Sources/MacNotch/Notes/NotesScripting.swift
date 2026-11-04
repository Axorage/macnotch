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


    // MARK: Folder listing

    static let fieldSep = "\u{1F}", recordSep = "\u{1E}"

    static let listChangedCode = -2700

    /// Batch-reads id/name/modification date/locked/plaintext of every note in the folder (a handful of Apple
    /// events regardless of size). Fails with -2700 if the counts disagree (the folder changed mid-read; the caller
    /// retries). Locked notes are skipped and their text is never emitted. Records: id, title, seconds, plaintext.
    static func listScript(folder: String) -> String {
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
            set nms to name of every note of fol
            set mds to modification date of every note of fol
            set lks to password protected of every note of fol
            set n to count of ids
            if (count of nms) is not n or (count of mds) is not n or (count of lks) is not n then error "list changed" number \(listChangedCode)
            if n is 0 then return ""
            set pts to {}
            try
                set pts to plaintext of every note of fol
            end try
            set hasPT to ((count of pts) is n)
            set out to ""
            repeat with k from 1 to n
                if (item k of lks) is false then
                    set t to ""
                    if hasPT then
                        set t to item k of pts
                        if (length of t) > 160 then set t to text 1 thru 160 of t
                    end if
                    \(secondsTextSnippet(of: "(item k of mds) - epoch", into: "mdText"))
                    set out to out & (item k of ids) & fs & (item k of nms) & fs & mdText & fs & t & rs
                end if
            end repeat
            return out
        end tell
        """
    }

    func fireAndForget(_ source: String) {
        adjust(1)
        queue.async {
            defer { self.adjust(-1) }
            var err: NSDictionary?
            _ = NSAppleScript(source: Self.withTimeout(source))?.executeAndReturnError(&err)
        }
    }

    /// Selects the note (by scripting id) in Notes and brings Notes to the front.
    static func showScript(id: String) -> String {
        """
        tell application "Notes"
            show note id "\(escape(id))"
            activate
        end tell
        """
    }

    // MARK: Folder names

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
}
