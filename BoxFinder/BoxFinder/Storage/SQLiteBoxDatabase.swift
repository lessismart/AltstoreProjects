import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum BoxDatabaseError: LocalizedError, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case executionFailed(String)
    case invalidInput(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "Could not open local inventory database: \(message)"
        case .prepareFailed(let message): return "Database query error: \(message)"
        case .executionFailed(let message): return "Database update failed: \(message)"
        case .invalidInput(let message): return message
        case .notFound(let message): return message
        }
    }
}

protocol BoxRepository: Sendable {
    func saveBox(id: Int64, name: String, location: String, notes: String) async throws -> BoxRecord
    func saveItem(
        id: Int64,
        boxId: Int64,
        name: String,
        category: String,
        quantity: Int,
        notes: String,
        source: String
    ) async throws -> ItemRecord
    func addPhoto(boxId: Int64, filename: String) async throws -> PhotoRecord
    func deleteBox(id: Int64) async throws -> [String]
    func deleteItem(id: Int64) async throws
    func deletePhoto(id: Int64) async throws -> String?
    func box(id: Int64) async throws -> BoxRecord?
    func box(code: String) async throws -> BoxRecord?
    func photo(id: Int64) async throws -> PhotoRecord?
    func allBoxes() async throws -> [BoxRecord]
    func items(boxId: Int64) async throws -> [ItemRecord]
    func photos(boxId: Int64) async throws -> [PhotoRecord]
    func allItems() async throws -> [ItemRecord]
    func allPhotos() async throws -> [PhotoRecord]
    func replaceAll(boxes: [BoxRecord], items: [ItemRecord], photos: [PhotoRecord]) async throws
}

actor SQLiteBoxDatabase: BoxRepository {
    private static let currentSchemaVersion: Int32 = 1
    private var db: OpaquePointer?

    init(databaseURL: URL? = nil) throws {
        let resolvedURL: URL
        if let databaseURL {
            resolvedURL = databaseURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let folder = appSupport.appendingPathComponent("BoxFinder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            resolvedURL = folder.appendingPathComponent("boxes.db")
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(resolvedURL.path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown error"
            if let handle { sqlite3_close(handle) }
            throw BoxDatabaseError.openFailed(msg)
        }
        guard let opened = handle else {
            throw BoxDatabaseError.openFailed("SQLite handle was nil")
        }
        self.db = opened

        try Self.executeRaw("PRAGMA foreign_keys = ON;", on: opened)
        try Self.executeRaw("PRAGMA busy_timeout = 10000;", on: opened)
        try Self.executeRaw("PRAGMA journal_mode = WAL;", on: opened)
        try Self.migrateIfNeeded(on: opened)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private static func migrateIfNeeded(on db: OpaquePointer) throws {
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK, let stmt {
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = sqlite3_column_int(stmt, 0)
            }
            sqlite3_finalize(stmt)
        }
        if version < 1 {
            try executeRaw("""
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS boxes(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    code TEXT UNIQUE,
                    name TEXT NOT NULL,
                    location TEXT NOT NULL,
                    notes TEXT NOT NULL DEFAULT '',
                    updated INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS items(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    box_id INTEGER NOT NULL REFERENCES boxes(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    category TEXT NOT NULL DEFAULT '',
                    quantity INTEGER NOT NULL,
                    notes TEXT NOT NULL DEFAULT '',
                    source TEXT NOT NULL DEFAULT 'manual'
                );
                CREATE TABLE IF NOT EXISTS photos(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    box_id INTEGER NOT NULL REFERENCES boxes(id) ON DELETE CASCADE,
                    filename TEXT NOT NULL UNIQUE
                );
                CREATE INDEX IF NOT EXISTS idx_items_box ON items(box_id);
                CREATE INDEX IF NOT EXISTS idx_photos_box ON photos(box_id);
                PRAGMA user_version = \(Self.currentSchemaVersion);
                COMMIT;
            """, on: db)
        }
    }

    func saveBox(id: Int64, name: String, location: String, notes: String) throws -> BoxRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedLocation.isEmpty else {
            throw BoxDatabaseError.invalidInput("Box name and location are required.")
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        if id > 0 {
            let sql = "UPDATE boxes SET name = ?, location = ?, notes = ?, updated = ? WHERE id = ?;"
            try withStatement(sql) { stmt in
                bindText(trimmedName, at: 1, in: stmt)
                bindText(trimmedLocation, at: 2, in: stmt)
                bindText(trimmedNotes, at: 3, in: stmt)
                sqlite3_bind_int64(stmt, 4, nowMs)
                sqlite3_bind_int64(stmt, 5, id)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw BoxDatabaseError.executionFailed(lastErrorMessage())
                }
            }
            guard let updated = try box(id: id) else {
                throw BoxDatabaseError.notFound("Box could not be found.")
            }
            return updated
        }

        let newId: Int64 = try inTransaction {
            let insertSQL = "INSERT INTO boxes(name, location, notes, updated) VALUES(?, ?, ?, ?);"
            try withStatement(insertSQL) { stmt in
                bindText(trimmedName, at: 1, in: stmt)
                bindText(trimmedLocation, at: 2, in: stmt)
                bindText(trimmedNotes, at: 3, in: stmt)
                sqlite3_bind_int64(stmt, 4, nowMs)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw BoxDatabaseError.executionFailed(lastErrorMessage())
                }
            }
            let insertedId = sqlite3_last_insert_rowid(requireDB())
            let code = Self.formatBoxCode(for: insertedId)
            try withStatement("UPDATE boxes SET code = ? WHERE id = ?;") { stmt in
                bindText(code, at: 1, in: stmt)
                sqlite3_bind_int64(stmt, 2, insertedId)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw BoxDatabaseError.executionFailed(lastErrorMessage())
                }
            }
            return insertedId
        }
        guard let created = try box(id: newId) else {
            throw BoxDatabaseError.executionFailed("Saved box could not be read back.")
        }
        return created
    }

    func saveItem(
        id: Int64,
        boxId: Int64,
        name: String,
        category: String,
        quantity: Int,
        notes: String,
        source: String
    ) throws -> ItemRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeSource = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "manual" : source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, (1...9999).contains(quantity) else {
            throw BoxDatabaseError.invalidInput("Enter an item name and quantity from 1 to 9999.")
        }

        if id > 0 {
            let sql = "UPDATE items SET box_id = ?, name = ?, category = ?, quantity = ?, notes = ?, source = ? WHERE id = ? AND box_id = ?;"
            try withStatement(sql) { stmt in
                sqlite3_bind_int64(stmt, 1, boxId)
                bindText(trimmedName, at: 2, in: stmt)
                bindText(trimmedCategory, at: 3, in: stmt)
                sqlite3_bind_int64(stmt, 4, Int64(quantity))
                bindText(trimmedNotes, at: 5, in: stmt)
                bindText(safeSource, at: 6, in: stmt)
                sqlite3_bind_int64(stmt, 7, id)
                sqlite3_bind_int64(stmt, 8, boxId)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw BoxDatabaseError.executionFailed(lastErrorMessage())
                }
            }
            return ItemRecord(
                id: id,
                boxId: boxId,
                name: trimmedName,
                category: trimmedCategory,
                quantity: quantity,
                notes: trimmedNotes,
                source: safeSource
            )
        }

        let insertSQL = "INSERT INTO items(box_id, name, category, quantity, notes, source) VALUES(?, ?, ?, ?, ?, ?);"
        try withStatement(insertSQL) { stmt in
            sqlite3_bind_int64(stmt, 1, boxId)
            bindText(trimmedName, at: 2, in: stmt)
            bindText(trimmedCategory, at: 3, in: stmt)
            sqlite3_bind_int64(stmt, 4, Int64(quantity))
            bindText(trimmedNotes, at: 5, in: stmt)
            bindText(safeSource, at: 6, in: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw BoxDatabaseError.executionFailed(lastErrorMessage())
            }
        }
        let insertedId = sqlite3_last_insert_rowid(requireDB())
        return ItemRecord(
            id: insertedId,
            boxId: boxId,
            name: trimmedName,
            category: trimmedCategory,
            quantity: quantity,
            notes: trimmedNotes,
            source: safeSource
        )
    }

    func addPhoto(boxId: Int64, filename: String) throws -> PhotoRecord {
        let sql = "INSERT INTO photos(box_id, filename) VALUES(?, ?);"
        try withStatement(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, boxId)
            bindText(filename, at: 2, in: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw BoxDatabaseError.executionFailed(lastErrorMessage())
            }
        }
        let insertedId = sqlite3_last_insert_rowid(requireDB())
        return PhotoRecord(id: insertedId, boxId: boxId, filename: filename)
    }

    func deleteBox(id: Int64) throws -> [String] {
        try inTransaction {
            let filenames = try photos(boxId: id).map(\.filename)
            try withStatement("DELETE FROM boxes WHERE id = ?;") { stmt in
                sqlite3_bind_int64(stmt, 1, id)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw BoxDatabaseError.executionFailed(lastErrorMessage())
                }
            }
            return filenames
        }
    }

    func deleteItem(id: Int64) throws {
        try withStatement("DELETE FROM items WHERE id = ?;") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw BoxDatabaseError.executionFailed(lastErrorMessage())
            }
        }
    }

    func deletePhoto(id: Int64) throws -> String? {
        try inTransaction {
            let existing = try photo(id: id)
            try withStatement("DELETE FROM photos WHERE id = ?;") { stmt in
                sqlite3_bind_int64(stmt, 1, id)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw BoxDatabaseError.executionFailed(lastErrorMessage())
                }
            }
            return existing?.filename
        }
    }

    func box(id: Int64) throws -> BoxRecord? {
        let rows = try queryBoxes("SELECT id, code, name, location, notes, updated FROM boxes WHERE id = ?;", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, id)
        })
        return rows.first
    }

    func box(code: String) throws -> BoxRecord? {
        let rows = try queryBoxes("SELECT id, code, name, location, notes, updated FROM boxes WHERE UPPER(code) = UPPER(?);", bind: { [self] stmt in
            self.bindText(code, at: 1, in: stmt)
        })
        return rows.first
    }

    func photo(id: Int64) throws -> PhotoRecord? {
        let rows = try queryPhotos("SELECT id, box_id, filename FROM photos WHERE id = ?;", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, id)
        })
        return rows.first
    }

    func allBoxes() throws -> [BoxRecord] {
        try queryBoxes("SELECT id, code, name, location, notes, updated FROM boxes ORDER BY location COLLATE NOCASE, name COLLATE NOCASE;", bind: nil)
    }

    func items(boxId: Int64) throws -> [ItemRecord] {
        try queryItems("SELECT id, box_id, name, category, quantity, notes, source FROM items WHERE box_id = ? ORDER BY name COLLATE NOCASE;", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, boxId)
        })
    }

    func photos(boxId: Int64) throws -> [PhotoRecord] {
        try queryPhotos("SELECT id, box_id, filename FROM photos WHERE box_id = ? ORDER BY id DESC;", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, boxId)
        })
    }

    func allItems() throws -> [ItemRecord] {
        try queryItems("SELECT id, box_id, name, category, quantity, notes, source FROM items ORDER BY id;", bind: nil)
    }

    func allPhotos() throws -> [PhotoRecord] {
        try queryPhotos("SELECT id, box_id, filename FROM photos ORDER BY id;", bind: nil)
    }

    func replaceAll(boxes: [BoxRecord], items: [ItemRecord], photos: [PhotoRecord]) throws {
        try inTransaction {
            try executeRaw("DELETE FROM photos; DELETE FROM items; DELETE FROM boxes;")

            let boxSQL = "INSERT INTO boxes(id, code, name, location, notes, updated) VALUES(?, ?, ?, ?, ?, ?);"
            for b in boxes {
                try withStatement(boxSQL) { stmt in
                    sqlite3_bind_int64(stmt, 1, b.id)
                    bindText(b.code, at: 2, in: stmt)
                    bindText(b.name, at: 3, in: stmt)
                    bindText(b.location, at: 4, in: stmt)
                    bindText(b.notes, at: 5, in: stmt)
                    sqlite3_bind_int64(stmt, 6, b.updated)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw BoxDatabaseError.executionFailed(lastErrorMessage())
                    }
                }
            }

            let itemSQL = "INSERT INTO items(id, box_id, name, category, quantity, notes, source) VALUES(?, ?, ?, ?, ?, ?, ?);"
            for item in items {
                try withStatement(itemSQL) { stmt in
                    sqlite3_bind_int64(stmt, 1, item.id)
                    sqlite3_bind_int64(stmt, 2, item.boxId)
                    bindText(item.name, at: 3, in: stmt)
                    bindText(item.category, at: 4, in: stmt)
                    sqlite3_bind_int64(stmt, 5, Int64(item.quantity))
                    bindText(item.notes, at: 6, in: stmt)
                    bindText(item.source, at: 7, in: stmt)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw BoxDatabaseError.executionFailed(lastErrorMessage())
                    }
                }
            }

            let photoSQL = "INSERT INTO photos(id, box_id, filename) VALUES(?, ?, ?);"
            for photo in photos {
                try withStatement(photoSQL) { stmt in
                    sqlite3_bind_int64(stmt, 1, photo.id)
                    sqlite3_bind_int64(stmt, 2, photo.boxId)
                    bindText(photo.filename, at: 3, in: stmt)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw BoxDatabaseError.executionFailed(lastErrorMessage())
                    }
                }
            }

            try syncAutoincrementSequence(table: "boxes", maxId: boxes.map(\.id).max() ?? 0)
            try syncAutoincrementSequence(table: "items", maxId: items.map(\.id).max() ?? 0)
            try syncAutoincrementSequence(table: "photos", maxId: photos.map(\.id).max() ?? 0)
        }
    }

    static func formatBoxCode(for id: Int64) -> String {
        String(format: "BX-%04lld", locale: Locale(identifier: "en_US_POSIX"), id)
    }

    // MARK: - Private SQLite Helpers

    private func syncAutoincrementSequence(table: String, maxId: Int64) throws {
        let hasSeq = try queryInt32("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sqlite_sequence';")
        guard hasSeq > 0 else { return }
        try withStatement("DELETE FROM sqlite_sequence WHERE name = ?;") { stmt in
            bindText(table, at: 1, in: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw BoxDatabaseError.executionFailed(lastErrorMessage())
            }
        }
        if maxId > 0 {
            try withStatement("INSERT INTO sqlite_sequence(name, seq) VALUES(?, ?);") { stmt in
                bindText(table, at: 1, in: stmt)
                sqlite3_bind_int64(stmt, 2, maxId)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw BoxDatabaseError.executionFailed(lastErrorMessage())
                }
            }
        }
    }

    private func requireDB() -> OpaquePointer {
        db!
    }

    private func lastErrorMessage() -> String {
        guard let db else { return "Database closed" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func executeRaw(_ sql: String) throws {
        try Self.executeRaw(sql, on: requireDB())
    }

    private static func executeRaw(_ sql: String, on db: OpaquePointer) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errPtr) != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errPtr { sqlite3_free(errPtr) }
            throw BoxDatabaseError.executionFailed(msg)
        }
    }

    private func inTransaction<T>(_ work: () throws -> T) throws -> T {
        try executeRaw("BEGIN IMMEDIATE;")
        do {
            let result = try work()
            try executeRaw("COMMIT;")
            return result
        } catch {
            try? executeRaw("ROLLBACK;")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(requireDB(), sql, -1, &stmt, nil) != SQLITE_OK {
            throw BoxDatabaseError.prepareFailed(lastErrorMessage())
        }
        guard let stmt else {
            throw BoxDatabaseError.prepareFailed("Statement allocation failed")
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func bindText(_ value: String, at index: Int32, in stmt: OpaquePointer) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func queryInt32(_ sql: String) throws -> Int32 {
        try withStatement(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }
            return sqlite3_column_int(stmt, 0)
        }
    }

    private func queryBoxes(_ sql: String, bind: ((OpaquePointer) -> Void)?) throws -> [BoxRecord] {
        try withStatement(sql) { stmt in
            bind?(stmt)
            var result: [BoxRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(BoxRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    code: columnText(stmt, 1),
                    name: columnText(stmt, 2),
                    location: columnText(stmt, 3),
                    notes: columnText(stmt, 4),
                    updated: sqlite3_column_int64(stmt, 5)
                ))
            }
            return result
        }
    }

    private func queryItems(_ sql: String, bind: ((OpaquePointer) -> Void)?) throws -> [ItemRecord] {
        try withStatement(sql) { stmt in
            bind?(stmt)
            var result: [ItemRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(ItemRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    boxId: sqlite3_column_int64(stmt, 1),
                    name: columnText(stmt, 2),
                    category: columnText(stmt, 3),
                    quantity: Int(sqlite3_column_int64(stmt, 4)),
                    notes: columnText(stmt, 5),
                    source: columnText(stmt, 6)
                ))
            }
            return result
        }
    }

    private func queryPhotos(_ sql: String, bind: ((OpaquePointer) -> Void)?) throws -> [PhotoRecord] {
        try withStatement(sql) { stmt in
            bind?(stmt)
            var result: [PhotoRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(PhotoRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    boxId: sqlite3_column_int64(stmt, 1),
                    filename: columnText(stmt, 2)
                ))
            }
            return result
        }
    }
}
