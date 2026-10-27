import Foundation

// MARK: - GraftDatabase
//
// Everything the phone knows, in SQLite. Replaces `graft_data.json`, which held
// every project, issue and link as one document and was rewritten whole after
// every tap, and the two queue files beside it.
//
// Each record is one row holding the same JSON the file held, so nothing about
// how a record is encoded or decoded changes here. Real columns can come later,
// when something needs to query them; `json_extract` covers the meantime. See
// docs/local-first.md.
//
// Not an actor and not Sendable: the store and the sync engine are both on the
// main actor, and so is every call into this.

final class GraftDatabase {

    /// The file. Application Support rather than Documents or Caches: iOS
    /// empties Caches under storage pressure, and Application Support is in the
    /// device backup, which for a phone with no server is the only other copy.
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("graft.sqlite3")
    }

    /// The record tables. One per list on `GraftStore`.
    enum Table: String, CaseIterable {
        case projects, issues, milestones, areas, links
        case savedViews = "saved_views"
    }

    /// The two halves of the sync queue.
    enum Queue: String {
        case pending = "pending_ops"
        case dropped = "dropped_ops"
    }

    private let db: SQLite
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    /// What each record table held after the last read or write, by id. Saving
    /// compares against this, which is what lets an edit to one issue write one
    /// row rather than all of them.
    private var written: [Table: [String: Stored]] = [:]

    private struct Stored: Equatable {
        let position: Int64
        let data: Data
    }

    /// Nil when the file can't be opened. The store then keeps using
    /// `graft_data.json` exactly as it did before this existed.
    static func open() -> GraftDatabase? {
        do {
            let db = try SQLite(path: fileURL.path)
            try migrate(db)
            return GraftDatabase(db)
        } catch {
            print("[graft] database unavailable, staying on the JSON file: \(error)")
            return nil
        }
    }

    private init(_ db: SQLite) {
        self.db = db
        let encoder = JSONEncoder()
        // Sorted, so the same record always encodes to the same bytes and an
        // unchanged row compares equal to what was written last time.
        encoder.outputFormatting = .sortedKeys
        self.encoder = encoder
    }

    private static func migrate(_ db: SQLite) throws {
        var sql = ""
        for table in Table.allCases {
            sql += """
            CREATE TABLE IF NOT EXISTS \(table.rawValue) (
              id       TEXT PRIMARY KEY,
              position INTEGER NOT NULL DEFAULT 0,
              data     BLOB NOT NULL
            );

            """
        }
        sql += """
        CREATE TABLE IF NOT EXISTS pending_ops (
          position INTEGER PRIMARY KEY,
          id       TEXT NOT NULL,
          data     BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS dropped_ops (
          position INTEGER PRIMARY KEY,
          id       TEXT NOT NULL,
          data     BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS meta (
          key   TEXT PRIMARY KEY,
          value TEXT
        );
        """
        try db.execute(sql)
    }

    // MARK: - The library

    /// True when no record table has a row in it — the only state an import
    /// from the old file is allowed to write into.
    var isLibraryEmpty: Bool {
        Table.allCases.allSatisfy { rowCount($0) == 0 }
    }

    private func rowCount(_ table: Table) -> Int {
        Int((try? db.query("SELECT COUNT(*) AS n FROM \(table.rawValue)").first?.int("n")) ?? 0)
    }

    /// Everything, in the order it was saved. A row that no longer decodes is
    /// skipped rather than costing the whole library, and left in place for a
    /// later build that can read it: it never enters `written`, so no save
    /// will delete it.
    func loadLibrary() -> GraftCachedData {
        GraftCachedData(
            projects: load(GraftProject.self, from: .projects),
            issues: load(GraftIssue.self, from: .issues),
            milestones: load(GraftMilestone.self, from: .milestones),
            areas: load(GraftArea.self, from: .areas),
            links: load(GraftLink.self, from: .links),
            savedViews: load(GraftSavedView.self, from: .savedViews)
        )
    }

    private func load<T: Decodable & Identifiable>(_ type: T.Type, from table: Table) -> [T] where T.ID == String {
        guard let rows = try? db.query("SELECT position, data FROM \(table.rawValue) ORDER BY position, rowid") else {
            return []
        }
        var records: [T] = []
        var seen: [String: Stored] = [:]
        for row in rows {
            guard let data = row.data("data"),
                  let record = try? decoder.decode(T.self, from: data) else { continue }
            records.append(record)
            seen[record.id] = Stored(position: row.int("position") ?? 0, data: data)
        }
        written[table] = seen
        return records
    }

    /// Makes the tables match `library`, writing only the rows that differ
    /// from what is already there. One transaction for the lot, so a save is
    /// never half applied.
    func saveLibrary(_ library: GraftCachedData) {
        // Built on a copy and committed only when the transaction is, so a
        // failed save does not leave `written` describing rows that aren't.
        var next = written
        do {
            try db.transaction {
                try writeLocked(library.projects, to: .projects, tracking: &next)
                try writeLocked(library.issues, to: .issues, tracking: &next)
                try writeLocked(library.milestones, to: .milestones, tracking: &next)
                try writeLocked(library.areas ?? [], to: .areas, tracking: &next)
                try writeLocked(library.links ?? [], to: .links, tracking: &next)
                try writeLocked(library.savedViews ?? [], to: .savedViews, tracking: &next)
            }
            written = next
        } catch {
            print("[graft] database save failed: \(error)")
        }
    }

    /// Only legal from inside `transaction`.
    ///
    /// Positions keep the list's order without renumbering it. A row keeps the
    /// position it already has for as long as that is still after the row
    /// before it, so deleting from the middle of a list writes nothing but the
    /// delete, and appending writes only the new row. Only a row that has moved
    /// ahead of its neighbours is given a new position.
    private func writeLocked<T: Encodable & Identifiable>(
        _ records: [T],
        to table: Table,
        tracking next: inout [Table: [String: Stored]]
    ) throws where T.ID == String {
        var previous = next[table] ?? [:]
        var current: [String: Stored] = [:]
        current.reserveCapacity(records.count)
        var last: Int64 = -1

        for record in records {
            // A list holding the same id twice is a bug somewhere else, but it
            // must not become two writes to one row with different positions.
            guard current[record.id] == nil else { continue }
            let data = try encoder.encode(record)
            let old = previous.removeValue(forKey: record.id)

            let position: Int64
            if let old, old.position > last {
                position = old.position
            } else {
                position = last + 1
            }
            last = position

            let stored = Stored(position: position, data: data)
            current[record.id] = stored
            if stored != old {
                try db.unsafeRun("""
                    INSERT INTO \(table.rawValue) (id, position, data) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET position = excluded.position, data = excluded.data
                    """, [record.id, position, data])
            }
        }

        // Whatever was written before and is not in the list any more.
        for id in previous.keys {
            try db.unsafeRun("DELETE FROM \(table.rawValue) WHERE id = ?", [id])
        }
        next[table] = current
    }

    /// Every id in every record table, for checking an import landed.
    func libraryIds() -> Set<String> {
        var ids = Set<String>()
        for table in Table.allCases {
            let rows = (try? db.query("SELECT id FROM \(table.rawValue)")) ?? []
            for row in rows {
                if let id = row.string("id") { ids.insert(id) }
            }
        }
        return ids
    }

    /// Empties every record table. Only for undoing an import that did not
    /// verify, so the next launch can try it again from the file.
    func clearLibrary() {
        do {
            try db.transaction {
                for table in Table.allCases {
                    try db.unsafeRun("DELETE FROM \(table.rawValue)")
                }
            }
            written = [:]
        } catch {
            print("[graft] database clear failed: \(error)")
        }
    }

    // MARK: - The sync queue

    /// A queue is a few dozen rows at most, so it is rewritten whole, the way
    /// the file it replaces was.
    func loadQueue<T: Decodable>(_ type: T.Type, from queue: Queue, decoder: JSONDecoder) -> [T] {
        guard let rows = try? db.query("SELECT data FROM \(queue.rawValue) ORDER BY position") else {
            return []
        }
        return rows.compactMap { row in
            row.data("data").flatMap { try? decoder.decode(T.self, from: $0) }
        }
    }

    @discardableResult
    func saveQueue<T: Encodable & Identifiable>(_ ops: [T], to queue: Queue, encoder: JSONEncoder) -> Bool where T.ID == String {
        do {
            try db.transaction {
                try db.unsafeRun("DELETE FROM \(queue.rawValue)")
                for (position, op) in ops.enumerated() {
                    let data = try encoder.encode(op)
                    try db.unsafeRun(
                        "INSERT INTO \(queue.rawValue) (position, id, data) VALUES (?, ?, ?)",
                        [position, op.id, data]
                    )
                }
            }
            return true
        } catch {
            print("[graft] queue save failed for \(queue.rawValue): \(error)")
            return false
        }
    }

    func queueIds(_ queue: Queue) -> [String] {
        let rows = (try? db.query("SELECT id FROM \(queue.rawValue) ORDER BY position")) ?? []
        return rows.compactMap { $0.string("id") }
    }
}
