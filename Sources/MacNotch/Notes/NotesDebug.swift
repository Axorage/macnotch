import Foundation
import AppKit
import ApplicationServices
import os

/// Read-only diagnostics, only reachable through launch arguments. They never write to a note, never print titles or
/// text, and report to the unified log (category "probe") and to /tmp/macnotch-debug.txt.
enum NotesDebug {
    static let logger = Logger(subsystem: "com.eortizd.macnotch", category: "probe")
    static let path = "/tmp/macnotch-debug.txt"

    static func emit(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: data) }
    }

    /// Every note of every folder except "Recently Deleted": ids only.
    static let allIDsScript = """
        tell application "Notes"
            set rs to character id 30
            set out to ""
            repeat with f in every folder
                try
                    if (name of f) is not "Recently Deleted" then
                        set ids to id of every note of f
                        repeat with i in ids
                            set out to out & (i as text) & rs
                        end repeat
                    end if
                end try
            end repeat
            return out
        end tell
        """

    private static func launchNotes() async {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false; cfg.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        for _ in 0..<40 where NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    // MARK: --debug-probe-all

    /// Runs the real decision pipeline (probe script -> NotesProvider.decide -> mode choice) for every note, with no editor.
    static func probeAll(legacy: Bool) async {
        try? FileManager.default.removeItem(atPath: path)
        await launchNotes()
        let trusted = AXIsProcessTrusted()
        emit("probe-all start legacyLimit=\(legacy) axTrusted=\(trusted)")
        let listed = await NotesScripting.shared.runDetailed(allIDsScript)
        guard case .success(let raw) = listed else { emit("probe-all: cannot list notes: \(listed)"); return }
        var seen = Set<String>()
        let ids = raw.components(separatedBy: NotesScripting.recordSep).filter { !$0.isEmpty && seen.insert($0).inserted }
        emit("probe-all notes=\(ids.count)")
        var modes: [String: Int] = [:], reasons: [String: Int] = [:], codes: [String: Int] = [:]
        for (n, id) in ids.enumerated() {
            let started = Date()
            var mode = "readOnly", reason = "", code = ""
            var decideMS = -1
            var plainLen = -1, htmlLen = -1, att = -1
            let r = await NotesScripting.shared.runDetailed(NotesScripting.editProbeScript(uri: id))
            switch r {
            case .failure(let e):
                reason = e.code == NotesScripting.timeoutCode ? "scriptTimeout" : "scriptError(\(e.code))"
            case .success(let out) where out == "!LOCKED":
                reason = "locked"
            case .success(let out):
                let f = out.components(separatedBy: NotesScripting.fieldSep)
                if f.count >= 4, let a = Int(f[0]), let mod = Int(f[1]) {
                    let html = f[3...].joined(separator: NotesScripting.fieldSep)
                    plainLen = f[2].utf16.count; htmlLen = html.utf16.count; att = a
                    let t0 = Date()
                    let d = NotesProvider.decide(attachments: a, mod: mod, html: html, plain: f[2], legacyLimit: legacy)
                    decideMS = Int(Date().timeIntervalSince(t0) * 1000)
                    code = d.code
                    switch d.probe {
                    case .editable: mode = "htmlEditable"
                    case .unsafe: if trusted { mode = "notesBacked" } else { reason = "needsAccessibility" }
                    case .tooLong: reason = "tooLong"
                    case .locked: reason = "locked"
                    case .unavailable: reason = "unavailable"
                    }
                } else { reason = "badProbeOutput" }
            }
            if reason.isEmpty { /* editable */ } else { mode = "readOnly" }
            modes[mode, default: 0] += 1
            if !reason.isEmpty { reasons[reason, default: 0] += 1 }
            if !code.isEmpty { codes[code.split(separator: ":").first.map(String.init) ?? code, default: 0] += 1 }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            emit("note \(n + 1)/\(ids.count) id=\(id.split(separator: "/").last ?? "?") mode=\(mode)\(reason.isEmpty ? "" : " reason=\(reason)") code=[\(code.prefix(160))] att=\(att) plainLen=\(plainLen) htmlLen=\(htmlLen) ms=\(ms) decideMs=\(decideMS)")
        }
        emit("SUMMARY notes=\(ids.count) axTrusted=\(trusted) modes=\(modes.sorted { $0.key < $1.key }) readOnlyReasons=\(reasons.sorted { $0.key < $1.key }) decisionCodes=\(codes.sorted { $0.key < $1.key })")
        emit("probe-all done")
    }

    // MARK: --debug-ax-begin=<note id>

    private static func step(_ name: String, _ ok: Bool, _ detail: String = "") {
        emit("ax-begin \(ok ? "PASS" : "FAIL") \(name) \(detail)")
    }

    /// Everything NotesAX.begin does, step by step, then STOPS before any write. `show` changes which note Notes displays.
    static func axBegin(arg: String) async {
        try? FileManager.default.removeItem(atPath: path)
        await launchNotes()
        let uri = arg
        let trusted = AXIsProcessTrusted()
        step("AXIsProcessTrusted", trusted)
        guard trusted else { emit("ax-begin STOP: grant Accessibility to \(Bundle.main.bundlePath)"); return }
        let r = await NotesScripting.shared.runDetailed(NotesScripting.editProbeScript(uri: uri))
        guard case .success(let out) = r, out != "!LOCKED" else { step("probe", false, "\(r)"); return }
        let f = out.components(separatedBy: NotesScripting.fieldSep)
        guard f.count >= 4, let att = Int(f[0]) else { step("probe", false, "bad output"); return }
        let plain = f[2], html = f[3...].joined(separator: NotesScripting.fieldSep)
        let d = NotesProvider.decide(attachments: att, mod: Int(f[1]) ?? 0, html: html, plain: plain)
        step("decision", true, "code=[\(d.code)] attachments=\(att) plainUTF16=\(plain.utf16.count) htmlUTF16=\(html.utf16.count)")
        await NotesAX.run { axBeginSteps(uri: uri, plain: plain, html: html) }
    }

    private static func axBeginSteps(uri: String, plain: String, html: String) {
        let mem = NotesAX.remember()
        defer { NotesAX.restore(mem, settle: true, step: "debug end") }
        let shown = NotesAX.showInBackgroundForDebug(uri)
        step("show note (no activate)", shown, "")
        guard shown else { return }
        var area: AXUIElement?
        var value: String?
        var lastMismatch = false
        var sawArea = false
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.075)
            guard let a = NotesAX.locate() else { continue }
            sawArea = true
            guard let v = NotesAX.value(of: a) else { continue }
            if !NotesAX.looselyEqual(v, plain) { lastMismatch = true; continue }
            area = a; value = v; lastMismatch = false; break
        }
        step("find AX text area", sawArea)
        step("read AXValue", value != nil || lastMismatch, value.map { "utf16=\($0.utf16.count) fffc=\(NotesTextDiff.placeholderCount($0))" } ?? "")
        guard let area, let v = value else {
            step("identity (AXValue ~ plaintext)", false, "text never matched plaintext")
            if let a = NotesAX.locate(), let v = NotesAX.value(of: a) { alignmentReport(v, plain) }
            return
        }
        step("identity (AXValue ~ plaintext)", true)
        let sel = NotesAX.selectedIDForDebug()
        step("selection is this note", sel == uri, sel.isEmpty ? "selection unreadable" : "")
        alignmentReport(v, plain)
        let a = NoteAXDisplay.attributed(baseline: v, html: html)
        step("editor text == AX text (chips are U+FFFC)", a.string.utf16.elementsEqual(v.utf16), "editor=\(a.length) ax=\(v.utf16.count)")
        step("HTML styling matches AX text", NoteAXDisplay.stylingMatches(baseline: v, html: html))
        step("chips == attachments", NotesTextDiff.placeholderCount(v) == NotesTextDiff.placeholderCount(a.string), "chips=\(NotesTextDiff.placeholderCount(a.string))")
        step("self-diff is empty", NotesTextDiff.edits(from: v, to: a.string)?.isEmpty == true)
        step("AXSelectedText settable (flag only, NOT set)", NotesAX.isSettableForDebug(area, kAXSelectedTextAttribute))
        step("AXSelectedTextRange settable (flag only)", NotesAX.isSettableForDebug(area, kAXSelectedTextRangeAttribute))
        emit("ax-begin STOP (nothing was written)")
    }

    /// Text-free description of how AX text and plaintext differ (character classes only).
    private static func alignmentReport(_ ax: String, _ plain: String) {
        func classes(_ s: String) -> String {
            var c: [String: Int] = [:]
            for u in s.unicodeScalars {
                switch u.value {
                case 0xFFFC: c["FFFC", default: 0] += 1
                case 0xA0: c["nbsp", default: 0] += 1
                case 0x2028, 0x2029: c["U2028/9", default: 0] += 1
                case 9: c["tab", default: 0] += 1
                case 10: c["lf", default: 0] += 1
                case 0x2022, 0x25E6, 0x25AA, 0x2013, 0x2014: c["marker", default: 0] += 1
                default: break
                }
            }
            return c.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
        emit("ax-begin alignment axUTF16=\(ax.utf16.count) plainUTF16=\(plain.utf16.count) ax[\(classes(ax))] plain[\(classes(plain))] exactEqual=\(ax == plain)")
    }
}
