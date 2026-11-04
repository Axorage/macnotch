import Foundation
import SQLite3

struct NoteItem: Identifiable, Hashable {
    let id: Int64          // Z_PK
    let title: String
    let snippet: String
    let modified: Date
}

enum NotesStatus: Equatable {
    case loading, ok, needsFullDiskAccess, needsAutomationAccess, notesNotRunning, folderNotFound(String), empty, error(String)
}

enum NotesSource: Equatable { case database, appleScript }

struct NotesQueryResult {
    var notes: [NoteItem]
    var folderCount: Int
    var storeUUID: String?
}

enum NotesDBError: Error {
    case needsFullDiskAccess
    case other(String)
}

/// Read-only access to the Apple Notes store. Synchronous; call off the main thread.
enum NotesDatabase {
    static var defaultPath: String {
        NSHomeDirectory() + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    }

    static func query(path: String = defaultPath, folderName: String, limit: Int = 50) throws -> NotesQueryResult {
        do { return try queryUncached(path: path, folderName: folderName, limit: limit) }
        catch { invalidateSchemaCache(); throw error }
    }

    private static func queryUncached(path: String, folderName: String, limit: Int) throws -> NotesQueryResult {
        var db: OpaquePointer?
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let uri = "file:\(encoded)?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { if db != nil { sqlite3_close(db) } }
        guard rc == SQLITE_OK, let db else { throw mapError(rc, db, path) }
        sqlite3_busy_timeout(db, 1500)

        let schema = try cachedSchema(db, path: path)
        let noteEnt = schema.noteEnt, folderEnt = schema.folderEnt
        let folderWhere = schema.folderWhere
        let noteTitle = schema.noteTitle, snippetExpr = schema.snippetExpr, modExpr = schema.modExpr
        let pwd = schema.noteFilter

        var result = NotesQueryResult(notes: [], folderCount: 0, storeUUID: storeUUID(db))

        // Folder count
        try run(db, "SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT f WHERE \(folderWhere)",
                binds: { st in
                    sqlite3_bind_int64(st, 1, folderEnt)
                    bindText(st, 2, folderName)
                }) { st in result.folderCount = Int(sqlite3_column_int64(st, 0)) }
        if result.folderCount == 0 { return result }

        let sql = """
        SELECT n.Z_PK, n.\(noteTitle), \(snippetExpr), \(modExpr)
        FROM ZICCLOUDSYNCINGOBJECT n
        WHERE n.Z_ENT = ?3
          AND n.ZFOLDER IN (SELECT f.Z_PK FROM ZICCLOUDSYNCINGOBJECT f WHERE \(folderWhere))\(pwd)
        ORDER BY \(modExpr) DESC LIMIT ?4
        """
        try run(db, sql, binds: { st in
            sqlite3_bind_int64(st, 1, folderEnt)
            bindText(st, 2, folderName)
            sqlite3_bind_int64(st, 3, noteEnt)
            sqlite3_bind_int(st, 4, Int32(limit))
        }) { st in
            let title = text(st, 1).trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = text(st, 2).trimmingCharacters(in: .whitespacesAndNewlines)
            result.notes.append(NoteItem(
                id: sqlite3_column_int64(st, 0),
                title: title.isEmpty ? "Untitled" : title,
                snippet: snippet,
                modified: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 3))))
        }
        return result
    }

    /// Unique, sorted names of real folders (not Recently Deleted, deleted or smart folders). Call off the main thread.
    static func folderNames(path: String = defaultPath) throws -> [String] {
        do { return try folderNamesUncached(path: path) }
        catch { invalidateSchemaCache(); throw error }
    }

    private static func folderNamesUncached(path: String) throws -> [String] {
        var db: OpaquePointer?
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let rc = sqlite3_open_v2("file:\(encoded)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { if db != nil { sqlite3_close(db) } }
        guard rc == SQLITE_OK, let db else { throw mapError(rc, db, path) }
        sqlite3_busy_timeout(db, 1500)
        let schema = try cachedSchema(db, path: path)
        var names = Set<String>()
        try run(db, "SELECT f.\(schema.folderTitle) FROM ZICCLOUDSYNCINGOBJECT f WHERE f.Z_ENT = ?1\(schema.folderListFilter)",
                binds: { sqlite3_bind_int64($0, 1, schema.folderEnt) }) { st in
            let n = text(st, 0).trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { names.insert(n) }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: schema (cached across reloads)

    struct Schema {
        var noteTitle: String, snippetExpr: String, modExpr: String
        var folderWhere: String
        var noteFilter: String      // extra AND clauses on n (locked / crypto / deleted)
        var noteEnt: Int64 = 0, folderEnt: Int64 = 0
        var folderTitle = ""
        var folderListFilter = ""   // extra AND clauses on f for the folder picker (no trash / deleted / smart)
    }

    /// Pure: builds SQL fragments from the column set. Fails CLOSED when the lock column is missing.
    static func buildSchema(columns cols: Set<String>) throws -> Schema {
        guard !cols.isEmpty else { throw NotesDBError.other("Notes schema not recognised") }
        func pick(_ names: [String]) -> String? { names.first { cols.contains($0) } }
        guard let noteTitle = pick(["ZTITLE1", "ZTITLE"]),
              let folderTitle = pick(["ZTITLE2", "ZTITLE"]),
              cols.contains("ZFOLDER"),
              cols.contains("ZISPASSWORDPROTECTED") else {
            throw NotesDBError.other("Notes schema not recognised")
        }
        let modCol = pick(["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"])
        var filter = " AND COALESCE(n.ZISPASSWORDPROTECTED,0) = 0"
        for c in ["ZCRYPTOINITIALIZATIONVECTOR", "ZCRYPTOTAG"] where cols.contains(c) {
            filter += " AND n.\(c) IS NULL"
        }
        if cols.contains("ZMARKEDFORDELETION") { filter += " AND COALESCE(n.ZMARKEDFORDELETION,0) != 1" }
        let fDel = cols.contains("ZMARKEDFORDELETION") ? " AND COALESCE(f.ZMARKEDFORDELETION,0) != 1" : ""
        let fTrash = cols.contains("ZFOLDERTYPE") ? " AND COALESCE(f.ZFOLDERTYPE,0) != 1" : ""
        let fSmart = cols.contains("ZFOLDERTYPE") ? " AND COALESCE(f.ZFOLDERTYPE,0) != 3" : ""
        return Schema(
            noteTitle: noteTitle,
            snippetExpr: cols.contains("ZSNIPPET") ? "n.ZSNIPPET" : "''",
            modExpr: modCol.map { "n.\($0)" } ?? "0",
            folderWhere: "f.Z_ENT = ?1 AND f.\(folderTitle) = ?2 COLLATE NOCASE\(fTrash)\(fDel)",
            noteFilter: filter,
            folderTitle: folderTitle,
            folderListFilter: fTrash + fDel + fSmart)
    }

    private static let schemaLock = NSLock()
    private nonisolated(unsafe) static var schemaCache: [String: Schema] = [:]

    private static func cachedSchema(_ db: OpaquePointer, path: String) throws -> Schema {
        schemaLock.lock(); let hit = schemaCache[path]; schemaLock.unlock()
        if let hit { return hit }
        var s = try buildSchema(columns: try columns(db, table: "ZICCLOUDSYNCINGOBJECT"))
        s.noteEnt = try entityId(db, "ICNote")
        s.folderEnt = try entityId(db, "ICFolder")
        schemaLock.lock(); schemaCache[path] = s; schemaLock.unlock()
        return s
    }

    static func invalidateSchemaCache() {
        schemaLock.lock(); schemaCache.removeAll(); schemaLock.unlock()
    }

    /// Silent Full Disk Access probe. Never prompts. Tries several FDA-protected files; if any can be read,
    /// FDA is on. A missing file (ENOENT) is inconclusive, only EPERM/EACCES means "denied".
    static func hasFullDiskAccess() -> Bool {
        fdaProbes().contains { $0.ok }
    }

    static func fdaProbes() -> [(path: String, ok: Bool, errno: Int32)] {
        let h = NSHomeDirectory()
        let paths = [h + "/Library/Application Support/com.apple.TCC/TCC.db",
                     "/Library/Application Support/com.apple.TCC/TCC.db",
                     h + "/Library/Safari/Bookmarks.plist",
                     h + "/Library/Messages/chat.db",
                     defaultPath]
        return paths.map { p in
            let fd = Darwin.open(p, O_RDONLY)
            if fd < 0 { return (p, false, errno) }
            defer { Darwin.close(fd) }
            var b: UInt8 = 0
            if Darwin.read(fd, &b, 1) == 1 { return (p, true, 0) }
            return (p, false, errno)
        }
    }

    // MARK: helpers

    private static func mapError(_ rc: Int32, _ db: OpaquePointer?, _ path: String) -> NotesDBError {
        let ext = db.map { sqlite3_extended_errcode($0) } ?? rc
        let primary = ext & 0xFF
        if primary == SQLITE_CANTOPEN || primary == SQLITE_AUTH || primary == SQLITE_PERM
            || primary == SQLITE_READONLY || primary == SQLITE_IOERR {
            return .needsFullDiskAccess
        }
        let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
        if msg.lowercased().contains("authorization") || msg.lowercased().contains("not permitted") {
            return .needsFullDiskAccess
        }
        return .other(msg)
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &st, nil)
        guard rc == SQLITE_OK, let st else {
            throw mapError(rc, db, "")
        }
        return st
    }

    private static func run(_ db: OpaquePointer, _ sql: String,
                            binds: (OpaquePointer) -> Void = { _ in },
                            row: (OpaquePointer) -> Void) throws {
        let st = try prepare(db, sql)
        defer { sqlite3_finalize(st) }
        binds(st)
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { row(st) }
            else if rc == SQLITE_DONE { break }
            else { throw mapError(rc, db, "") }
        }
    }

    private static func columns(_ db: OpaquePointer, table: String) throws -> Set<String> {
        var out = Set<String>()
        try run(db, "PRAGMA table_info(\(table))") { st in out.insert(text(st, 1)) }
        return out
    }

    private static func entityId(_ db: OpaquePointer, _ name: String) throws -> Int64 {
        var id: Int64?
        try run(db, "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = ?1", binds: { bindText($0, 1, name) }) {
            id = sqlite3_column_int64($0, 0)
        }
        guard let id else { throw NotesDBError.other("Entity \(name) not found") }
        return id
    }

    private static func storeUUID(_ db: OpaquePointer) -> String? {
        var u: String?
        try? run(db, "SELECT Z_UUID FROM Z_METADATA LIMIT 1") { u = text($0, 0) }
        return (u?.isEmpty ?? true) ? nil : u
    }

    private static func text(_ st: OpaquePointer, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static func bindText(_ st: OpaquePointer, _ i: Int32, _ s: String) {
        sqlite3_bind_text(st, i, s, -1, transient)
    }
}
