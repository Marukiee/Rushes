import Foundation

/// The memory of the app: which cards it has seen, which files it already copied or was told to skip,
/// every import with its numbers, the names given to card folders and what was chosen in the library.
///
/// Files are recognised by name, size and time, not by name alone: a card that was formatted starts
/// numbering at C0001 again, and those clips must not be taken for the old ones.
public final class Ledger: @unchecked Sendable {
    public struct CardRecord: Sendable, Hashable {
        public var uuid: String
        public var name: String
        public var number: Int
        public var folder: String
        public var firstSeen: Date
        public var lastSeen: Date

        public init(uuid: String, name: String, number: Int, folder: String, firstSeen: Date, lastSeen: Date) {
            self.uuid = uuid
            self.name = name
            self.number = number
            self.folder = folder
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
        }
    }

    public struct ImportRecord: Sendable, Identifiable, Hashable {
        public var id: Int64
        public var cardUUID: String
        public var cardName: String
        public var folder: String
        public var label: String
        public var started: Date
        public var finished: Date?
        public var files: Int
        public var bytes: UInt64
        public var skippedFiles: Int
        public var skippedBytes: UInt64
        public var duration: TimeInterval
        public var status: String
        public var verified: Bool
        public var backupFolder: String?
        public var shotFrom: Date?
        public var shotTo: Date?
        public var sentToResolve: Bool
    }

    public enum ImportStatus {
        public static let running = "running"
        public static let done = "done"
        public static let failed = "failed"
        public static let cancelled = "cancelled"
    }

    private let db: SQLiteDB
    private let lock = NSLock()

    public init(path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        db = try SQLiteDB(path: path)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("PRAGMA synchronous=NORMAL")
        try migrate()
    }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS cards (
            uuid TEXT PRIMARY KEY, name TEXT, number INTEGER, folder TEXT, first_seen INTEGER, last_seen INTEGER
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS imports (
            id INTEGER PRIMARY KEY AUTOINCREMENT, card_uuid TEXT, card_name TEXT, folder TEXT, label TEXT,
            started INTEGER, finished INTEGER, files INTEGER DEFAULT 0, bytes INTEGER DEFAULT 0,
            skipped_files INTEGER DEFAULT 0, skipped_bytes INTEGER DEFAULT 0, duration REAL DEFAULT 0,
            status TEXT, verified INTEGER DEFAULT 0, backup_folder TEXT, shot_from INTEGER, shot_to INTEGER,
            sent_to_resolve INTEGER DEFAULT 0
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT, import_id INTEGER, rel TEXT, size INTEGER, mtime INTEGER,
            hash TEXT, dest TEXT, kind TEXT
        )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS files_fp ON files(rel, size, mtime)")
        try db.execute("CREATE INDEX IF NOT EXISTS files_hash ON files(hash)")
        try db.execute("CREATE INDEX IF NOT EXISTS files_import ON files(import_id)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS skipped (
            rel TEXT, size INTEGER, mtime INTEGER, card_uuid TEXT, at INTEGER, PRIMARY KEY (rel, size, mtime)
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS choices (
            key TEXT PRIMARY KEY, verdict TEXT, rating INTEGER DEFAULT 0, at INTEGER
        )
        """)
        try db.execute("CREATE TABLE IF NOT EXISTS notes (key TEXT PRIMARY KEY, text TEXT)")
    }

    // MARK: Cards

    public func card(uuid: String) -> CardRecord? {
        locked {
            try? db.rows("SELECT uuid, name, number, folder, first_seen, last_seen FROM cards WHERE uuid = ?", [.text(uuid)])
                .first.map(cardRecord)
        }
    }

    public func allCards() -> [CardRecord] {
        locked { ((try? db.rows("SELECT uuid, name, number, folder, first_seen, last_seen FROM cards ORDER BY number")) ?? []).map(cardRecord) }
    }

    public func saveCard(_ card: CardRecord) {
        locked {
            try? db.execute("""
            INSERT INTO cards (uuid, name, number, folder, first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO UPDATE SET name = excluded.name, number = excluded.number, folder = excluded.folder, last_seen = excluded.last_seen
            """, [.text(card.uuid), .text(card.name), .int(Int64(card.number)), .text(card.folder),
                  .int(Int64(card.firstSeen.timeIntervalSince1970)), .int(Int64(card.lastSeen.timeIntervalSince1970))])
        }
    }

    public func highestCardNumber() -> Int {
        locked {
            let a = (try? db.scalarInt("SELECT MAX(number) FROM cards")) ?? nil
            return Int(a ?? 0)
        }
    }

    private func cardRecord(_ row: SQLiteDB.Row) -> CardRecord {
        CardRecord(
            uuid: row[0].text ?? "", name: row[1].text ?? "", number: Int(row[2].int ?? 0), folder: row[3].text ?? "",
            firstSeen: Date(timeIntervalSince1970: Double(row[4].int ?? 0)), lastSeen: Date(timeIntervalSince1970: Double(row[5].int ?? 0))
        )
    }

    // MARK: Files

    /// Whether this exact file was copied before, by any import.
    public func hasImported(_ entry: FileEntry) -> Bool {
        locked {
            ((try? db.scalarInt("SELECT 1 FROM files WHERE rel = ? AND size = ? AND mtime = ? LIMIT 1",
                                [.text(entry.rel.lowercased()), .int(Int64(entry.size)), .int(entry.modifiedSeconds)])) ?? nil) != nil
        }
    }

    public func wasSkipped(_ entry: FileEntry) -> Bool {
        locked {
            ((try? db.scalarInt("SELECT 1 FROM skipped WHERE rel = ? AND size = ? AND mtime = ? LIMIT 1",
                                [.text(entry.rel.lowercased()), .int(Int64(entry.size)), .int(entry.modifiedSeconds)])) ?? nil) != nil
        }
    }

    /// All fingerprints in one go, for sorting a whole card into new and known without a query per file.
    public func knownFingerprints() -> (imported: Set<String>, skipped: Set<String>) {
        locked {
            var imported = Set<String>(), skipped = Set<String>()
            _ = try? db.query("SELECT rel, size, mtime FROM files") { row in
                imported.insert("\(row[0].text ?? "")|\(row[1].int ?? 0)|\(row[2].int ?? 0)")
            }
            _ = try? db.query("SELECT rel, size, mtime FROM skipped") { row in
                skipped.insert("\(row[0].text ?? "")|\(row[1].int ?? 0)|\(row[2].int ?? 0)")
            }
            return (imported, skipped)
        }
    }

    public func markSkipped(_ entries: [FileEntry], cardUUID: String) {
        locked {
            try? db.transaction {
                for entry in entries {
                    try db.execute("INSERT OR REPLACE INTO skipped (rel, size, mtime, card_uuid, at) VALUES (?, ?, ?, ?, ?)",
                                   [.text(entry.rel.lowercased()), .int(Int64(entry.size)), .int(entry.modifiedSeconds),
                                    .text(cardUUID), .int(Int64(Date().timeIntervalSince1970))])
                }
            }
        }
    }

    public func unmarkSkipped(_ entries: [FileEntry]) {
        locked {
            try? db.transaction {
                for entry in entries {
                    try db.execute("DELETE FROM skipped WHERE rel = ? AND size = ? AND mtime = ?",
                                   [.text(entry.rel.lowercased()), .int(Int64(entry.size)), .int(entry.modifiedSeconds)])
                }
            }
        }
    }

    public func recordFile(importID: Int64, entry: FileEntry, hash: String, dest: String, kind: String) {
        locked {
            try? db.execute("INSERT INTO files (import_id, rel, size, mtime, hash, dest, kind) VALUES (?, ?, ?, ?, ?, ?, ?)",
                            [.int(importID), .text(entry.rel.lowercased()), .int(Int64(entry.size)), .int(entry.modifiedSeconds),
                             .text(hash), .text(dest), .text(kind)])
        }
    }

    /// Where a file with this content is already stored, from an import that is not the given one.
    public func existingCopy(withHash hash: String, excludingImport importID: Int64) -> String? {
        locked {
            try? db.rows("SELECT dest FROM files WHERE hash = ? AND import_id != ? LIMIT 1", [.text(hash), .int(importID)])
                .first?[0].text
        }
    }

    public func files(ofImport importID: Int64) -> [(rel: String, size: UInt64, hash: String, dest: String, kind: String)] {
        locked {
            ((try? db.rows("SELECT rel, size, hash, dest, kind FROM files WHERE import_id = ? ORDER BY id", [.int(importID)])) ?? [])
                .map { ($0[0].text ?? "", UInt64($0[1].int ?? 0), $0[2].text ?? "", $0[3].text ?? "", $0[4].text ?? "") }
        }
    }

    /// The hash of every copied file by where it was put, for finding the same content in two places.
    public func hashesByDestination() -> [String: String] {
        locked {
            var result: [String: String] = [:]
            _ = try? db.query("SELECT dest, hash FROM files") { row in
                if let dest = row[0].text, let hash = row[1].text { result[dest] = hash }
            }
            return result
        }
    }

    /// After the folder of a card was renamed or moved, so the destinations still point at real files.
    public func rewriteDestinations(from old: String, to new: String) {
        locked {
            try? db.transaction {
                try db.execute("UPDATE files SET dest = ? || substr(dest, ?) WHERE dest LIKE ? || '%'",
                               [.text(new), .int(Int64(old.count + 1)), .text(old)])
                try db.execute("UPDATE imports SET folder = ? || substr(folder, ?) WHERE folder LIKE ? || '%'",
                               [.text(new), .int(Int64(old.count + 1)), .text(old)])
                try db.execute("UPDATE cards SET folder = ? || substr(folder, ?) WHERE folder LIKE ? || '%'",
                               [.text(new), .int(Int64(old.count + 1)), .text(old)])
            }
        }
    }

    // MARK: Imports

    public func beginImport(cardUUID: String, cardName: String, folder: String, label: String, backupFolder: String?) -> Int64 {
        locked {
            try? db.execute("""
            INSERT INTO imports (card_uuid, card_name, folder, label, started, status, backup_folder) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.text(cardUUID), .text(cardName), .text(folder), .text(label), .int(Int64(Date().timeIntervalSince1970)),
                  .text(ImportStatus.running), .optional(backupFolder)])
            return db.lastInsertRowID
        }
    }

    public func finishImport(
        id: Int64, status: String, files: Int, bytes: UInt64, skippedFiles: Int, skippedBytes: UInt64,
        duration: TimeInterval, verified: Bool, shotFrom: Date?, shotTo: Date?
    ) {
        locked {
            try? db.execute("""
            UPDATE imports SET finished = ?, status = ?, files = ?, bytes = ?, skipped_files = ?, skipped_bytes = ?,
                duration = ?, verified = ?, shot_from = ?, shot_to = ? WHERE id = ?
            """, [.int(Int64(Date().timeIntervalSince1970)), .text(status), .int(Int64(files)), .int(Int64(bytes)),
                  .int(Int64(skippedFiles)), .int(Int64(skippedBytes)), .double(duration), .int(verified ? 1 : 0),
                  .optional(shotFrom.map { Int64($0.timeIntervalSince1970) }), .optional(shotTo.map { Int64($0.timeIntervalSince1970) }),
                  .int(id)])
        }
    }

    public func markSentToResolve(importID: Int64) {
        locked { try? db.execute("UPDATE imports SET sent_to_resolve = 1 WHERE id = ?", [.int(importID)]) }
    }

    public func updateImportLabel(id: Int64, label: String, folder: String) {
        locked { try? db.execute("UPDATE imports SET label = ?, folder = ? WHERE id = ?", [.text(label), .text(folder), .int(id)]) }
    }

    public func imports(limit: Int = 200) -> [ImportRecord] {
        locked {
            let rows = (try? db.rows("""
            SELECT id, card_uuid, card_name, folder, label, started, finished, files, bytes, skipped_files, skipped_bytes,
                   duration, status, verified, backup_folder, shot_from, shot_to, sent_to_resolve
            FROM imports ORDER BY started DESC LIMIT ?
            """, [.int(Int64(limit))])) ?? []
            return rows.map { row in
                ImportRecord(
                    id: row[0].int ?? 0, cardUUID: row[1].text ?? "", cardName: row[2].text ?? "", folder: row[3].text ?? "",
                    label: row[4].text ?? "", started: Date(timeIntervalSince1970: Double(row[5].int ?? 0)),
                    finished: row[6].int.map { Date(timeIntervalSince1970: Double($0)) }, files: Int(row[7].int ?? 0),
                    bytes: UInt64(row[8].int ?? 0), skippedFiles: Int(row[9].int ?? 0), skippedBytes: UInt64(row[10].int ?? 0),
                    duration: row[11].double ?? 0, status: row[12].text ?? "", verified: (row[13].int ?? 0) == 1,
                    backupFolder: row[14].text, shotFrom: row[15].int.map { Date(timeIntervalSince1970: Double($0)) },
                    shotTo: row[16].int.map { Date(timeIntervalSince1970: Double($0)) }, sentToResolve: (row[17].int ?? 0) == 1
                )
            }
        }
    }

    /// Imports that were running when the app stopped, so they can be offered again.
    public func interruptedImports() -> [ImportRecord] {
        imports().filter { $0.status == ImportStatus.running }
    }

    public func markInterrupted() {
        locked { try? db.execute("UPDATE imports SET status = ? WHERE status = ?", [.text(ImportStatus.cancelled), .text(ImportStatus.running)]) }
    }

    // MARK: Choices and notes of the library

    public func choice(forKey key: String) -> (verdict: String, rating: Int)? {
        locked {
            try? db.rows("SELECT verdict, rating FROM choices WHERE key = ?", [.text(key)]).first.map { ($0[0].text ?? "", Int($0[1].int ?? 0)) }
        }
    }

    public func allChoices() -> [String: (verdict: String, rating: Int)] {
        locked {
            var result: [String: (String, Int)] = [:]
            _ = try? db.query("SELECT key, verdict, rating FROM choices") { row in
                result[row[0].text ?? ""] = (row[1].text ?? "", Int(row[2].int ?? 0))
            }
            return result
        }
    }

    public func setChoice(key: String, verdict: String?, rating: Int) {
        locked {
            if verdict == nil, rating == 0 {
                try? db.execute("DELETE FROM choices WHERE key = ?", [.text(key)])
            } else {
                try? db.execute("INSERT OR REPLACE INTO choices (key, verdict, rating, at) VALUES (?, ?, ?, ?)",
                                [.text(key), .text(verdict ?? ""), .int(Int64(rating)), .int(Int64(Date().timeIntervalSince1970))])
            }
        }
    }

    public func note(forKey key: String) -> String? {
        locked { try? db.rows("SELECT text FROM notes WHERE key = ?", [.text(key)]).first?[0].text }
    }

    public func setNote(key: String, text: String) {
        locked {
            if text.isEmpty {
                try? db.execute("DELETE FROM notes WHERE key = ?", [.text(key)])
            } else {
                try? db.execute("INSERT OR REPLACE INTO notes (key, text) VALUES (?, ?)", [.text(key), .text(text)])
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
