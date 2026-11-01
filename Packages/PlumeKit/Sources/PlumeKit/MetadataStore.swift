import CryptoKit
import Foundation
import SQLite3
import Synchronization

/// A local mirror of the server's tree, as far as it has been listed: what
/// makes folders open instantly and offline, and what change detection
/// compares against. SQLite in WAL mode; each process opens its own file
/// (the app and the File Provider extension each track what *they* have
/// seen).
public final class MetadataStore: Sendable {
    private let connection: Mutex<Connection>

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let connection = try Connection(path: url.path(percentEncoded: false))
        try connection.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS items (
              path TEXT PRIMARY KEY NOT NULL,
              parent TEXT NOT NULL,
              file_id TEXT NOT NULL,
              is_dir INTEGER NOT NULL,
              size INTEGER NOT NULL,
              modified REAL,
              etag TEXT NOT NULL,
              content_type TEXT,
              permissions TEXT NOT NULL,
              favorite INTEGER NOT NULL,
              has_preview INTEGER NOT NULL,
              -- The folder's etag when its children were last listed; NULL
              -- for a folder never opened.
              listed_etag TEXT
            );
            CREATE INDEX IF NOT EXISTS items_parent ON items(parent);
            CREATE INDEX IF NOT EXISTS items_file_id ON items(file_id);
            CREATE TABLE IF NOT EXISTS pinned (path TEXT PRIMARY KEY NOT NULL);
            """)
        try Self.migrate(connection)
        self.connection = Mutex(connection)
    }

    /// The app's own store, in the group container.
    public static func named(_ name: String) throws -> MetadataStore {
        try MetadataStore(url: AppGroup.containerURL.appending(path: "Metadata/\(name).sqlite"))
    }

    public static func removeAllDatabases() {
        try? FileManager.default.removeItem(at: AppGroup.containerURL.appending(path: "Metadata", directoryHint: .isDirectory))
    }

    // MARK: Reading

    public func item(at path: RemotePath) -> RemoteItem? {
        query("SELECT \(Self.columns) FROM items WHERE path = ?", [path.rawValue]).first
    }

    public func item(fileID: String) -> RemoteItem? {
        query("SELECT \(Self.columns) FROM items WHERE file_id = ? LIMIT 1", [fileID]).first
    }

    public func children(of path: RemotePath) -> [RemoteItem] {
        query("SELECT \(Self.columns) FROM items WHERE parent = ? AND path != '' ORDER BY is_dir DESC, path",
              [path.rawValue])
            .sorted(by: Self.displayOrder)
    }

    public func children(of path: RemotePath, limit: Int, offset: Int) -> [RemoteItem] {
        query("SELECT \(Self.columns) FROM items WHERE parent = ? AND path != '' ORDER BY path LIMIT ? OFFSET ?",
              [path.rawValue, limit, offset])
    }

    /// The folder's etag at its last listing; `nil` if never listed.
    public func listedEtag(of path: RemotePath) -> String? {
        connection.withLock { db in
            try? db.rows("SELECT listed_etag FROM items WHERE path = ?", [path.rawValue]) { $0.text(0) }.first ?? nil
        }
    }

    /// Items whose name contains `term`, ignoring case and accents ("resume"
    /// finds "Résumé"): names starting with it first, then the most recent.
    /// A scan of an indexed column: a few milliseconds for 100,000 files.
    public func search(_ term: String, limit: Int = 200) -> [RemoteItem] {
        let folded = Self.fold(term.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return [] }
        let escaped = folded.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return query("""
            SELECT \(Self.columns) FROM items
            WHERE path != '' AND search_name LIKE ? ESCAPE '\\'
            ORDER BY search_name LIKE ? ESCAPE '\\' DESC, is_dir DESC, modified DESC LIMIT ?
            """, ["%" + escaped + "%", escaped + "%", limit])
    }

    /// How a name is compared in searches.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    public var count: Int {
        connection.withLock { db in
            (try? db.rows("SELECT count(*) FROM items", []) { Int($0.int(0)) }.first) ?? 0
        }
    }

    public func favorites() -> [RemoteItem] {
        query("SELECT \(Self.columns) FROM items WHERE favorite = 1 AND path != ''").sorted(by: Self.displayOrder)
    }

    /// Every item at or below `path` already known locally.
    public func subtree(of path: RemotePath) -> [RemoteItem] {
        guard !path.isRoot else { return query("SELECT \(Self.columns) FROM items") }
        return query("SELECT \(Self.columns) FROM items WHERE path = ? OR substr(path, 1, ?) = ?",
                     [path.rawValue, path.rawValue.unicodeScalars.count + 1, path.rawValue + "/"])
    }

    // MARK: Writing

    @discardableResult
    public func upsert(_ item: RemoteItem) -> RemoteItem {
        connection.withLock { db in
            let identified = (try? Self.identified(item, in: db)) ?? item
            try? Self.upsert(identified, in: db)
            return identified
        }
    }

    /// Items from a server without file ids (plain WebDAV) get one here:
    /// the one already known at their path, or a new one derived from it.
    public func identified(_ items: [RemoteItem]) -> [RemoteItem] {
        guard items.contains(where: { $0.fileID.isEmpty }) else { return items }
        return connection.withLock { db in items.map { (try? Self.identified($0, in: db)) ?? $0 } }
    }

    /// Records a rename or move done here, so the item and everything below
    /// it keep their ids at the new path.
    public func move(_ source: RemotePath, to destination: RemotePath) {
        guard source != destination, !source.isRoot else { return }
        connection.withLock { db in
            _ = try? db.transaction {
                _ = try Self.deleteSubtree(destination, in: db)
                let start = source.rawValue.unicodeScalars.count + 1
                try db.run("""
                    UPDATE items SET
                      parent = CASE WHEN path = ? THEN ? ELSE ? || substr(parent, ?) END,
                      path = ? || substr(path, ?)
                    WHERE path = ? OR substr(path, 1, ?) = ?
                    """, [source.rawValue, (destination.parent ?? .root).rawValue, destination.rawValue, start,
                          destination.rawValue, start,
                          source.rawValue, start, source.rawValue + "/"])
                try db.run("UPDATE items SET search_name = ? WHERE path = ?",
                           [Self.fold(destination.name), destination.rawValue])
            }
        }
    }

    /// Records a fresh listing of a folder. Returns the items that were known
    /// below it and no longer exist (with their whole subtrees).
    @discardableResult
    public func replaceChildren(of folder: RemoteItem, with children: [RemoteItem]) -> [RemoteItem] {
        connection.withLock { db in
            (try? db.transaction {
                let previous = try db.rows("SELECT \(Self.columns) FROM items WHERE parent = ? AND path != ''",
                                           [folder.path.rawValue], Self.decode)
                let current = Set(children.map(\.path))
                var removed: [RemoteItem] = []
                for old in previous where !current.contains(old.path) {
                    removed += try Self.deleteSubtree(old.path, in: db)
                }
                for child in children {
                    // A folder whose etag changed keeps its old listing etag:
                    // that's how the next sync knows to look inside.
                    try Self.upsert(try Self.identified(child, in: db), in: db)
                }
                try Self.upsert(try Self.identified(folder, in: db), in: db)
                try db.run("UPDATE items SET listed_etag = ? WHERE path = ?", [folder.etag, folder.path.rawValue])
                return removed
            }) ?? []
        }
    }

    @discardableResult
    public func remove(_ path: RemotePath) -> [RemoteItem] {
        connection.withLock { db in (try? db.transaction { try Self.deleteSubtree(path, in: db) }) ?? [] }
    }

    /// Forgets the whole tree (sign out).
    public func removeAll() {
        connection.withLock { db in try? db.execute("DELETE FROM items; DELETE FROM pinned;") }
    }

    // MARK: Available offline

    public func pin(_ path: RemotePath) {
        connection.withLock { db in try? db.run("INSERT OR IGNORE INTO pinned (path) VALUES (?)", [path.rawValue]) }
    }

    public func unpin(_ path: RemotePath) {
        connection.withLock { db in try? db.run("DELETE FROM pinned WHERE path = ?", [path.rawValue]) }
    }

    public func pinnedPaths() -> [RemotePath] {
        connection.withLock { db in
            (try? db.rows("SELECT path FROM pinned ORDER BY path", []) { RemotePath($0.text(0) ?? "") }) ?? []
        }
    }

    /// Pinned itself, or inside a pinned folder.
    public func isPinned(_ path: RemotePath) -> Bool {
        pinnedPaths().contains { $0.contains(path) }
    }

    // MARK: Rows

    private static let columns =
        "path, parent, file_id, is_dir, size, modified, etag, content_type, permissions, favorite, has_preview"

    private static func displayOrder(_ a: RemoteItem, _ b: RemoteItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private func query(_ sql: String, _ arguments: [Any?] = []) -> [RemoteItem] {
        connection.withLock { db in (try? db.rows(sql, arguments, Self.decode)) ?? [] }
    }

    private static func decode(_ row: Row) -> RemoteItem {
        RemoteItem(
            path: RemotePath(row.text(0) ?? ""),
            fileID: row.text(2) ?? "",
            isDirectory: row.int(3) != 0,
            size: row.int(4),
            modified: row.double(5).map { Date(timeIntervalSince1970: $0) },
            etag: row.text(6) ?? "",
            contentType: row.text(7),
            permissions: row.text(8) ?? "",
            isFavorite: row.int(9) != 0,
            hasPreview: row.int(10) != 0)
    }

    private static func identified(_ item: RemoteItem, in db: Connection) throws -> RemoteItem {
        guard item.fileID.isEmpty, !item.path.isRoot else { return item }
        var item = item
        if let known = try db.rows("SELECT file_id FROM items WHERE path = ?", [item.path.rawValue], { $0.text(0) ?? "" })
            .first, !known.isEmpty {
            item.fileID = known
            return item
        }
        let digest = SHA256.hash(data: Data(item.path.rawValue.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        var candidate = "w" + digest
        var attempt = 1
        while try !db.rows("SELECT 1 FROM items WHERE file_id = ? AND path != ? LIMIT 1",
                           [candidate, item.path.rawValue], { _ in true }).isEmpty {
            attempt += 1
            candidate = "w\(digest)-\(attempt)"
        }
        item.fileID = candidate
        return item
    }

    private static func upsert(_ item: RemoteItem, in db: Connection) throws {
        try db.run("""
            INSERT INTO items (path, parent, file_id, is_dir, size, modified, etag, content_type, permissions,
                               favorite, has_preview, search_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
              parent = excluded.parent, file_id = excluded.file_id, is_dir = excluded.is_dir,
              size = excluded.size, modified = excluded.modified, etag = excluded.etag,
              content_type = excluded.content_type, permissions = excluded.permissions,
              favorite = excluded.favorite, has_preview = excluded.has_preview,
              search_name = excluded.search_name,
              listed_etag = CASE WHEN excluded.is_dir THEN items.listed_etag ELSE NULL END
            """, [
                item.path.rawValue, (item.path.parent ?? .root).rawValue, item.fileID, item.isDirectory ? 1 : 0,
                item.size, item.modified?.timeIntervalSince1970, item.etag, item.contentType, item.permissions,
                item.isFavorite ? 1 : 0, item.hasPreview ? 1 : 0, fold(item.name),
            ])
    }

    /// Schema changes, numbered by `PRAGMA user_version`.
    private static func migrate(_ db: Connection) throws {
        let version = try db.rows("PRAGMA user_version", []) { $0.int(0) }.first ?? 0
        if version < 1 {
            // Names folded for search.
            let columns = try db.rows("PRAGMA table_info(items)", []) { $0.text(1) ?? "" }
            if !columns.contains("search_name") {
                try db.execute("ALTER TABLE items ADD COLUMN search_name TEXT NOT NULL DEFAULT ''")
            }
            try db.transaction {
                let rows = try db.rows("SELECT path FROM items", []) { $0.text(0) ?? "" }
                for path in rows {
                    try db.run("UPDATE items SET search_name = ? WHERE path = ?", [fold(RemotePath(path).name), path])
                }
            }
            try db.execute("PRAGMA user_version = 1")
        }
    }

    private static func deleteSubtree(_ path: RemotePath, in db: Connection) throws -> [RemoteItem] {
        let prefix = path.rawValue + "/"
        let condition = "path = ? OR substr(path, 1, ?) = ?"
        // SQLite counts code points, not Swift characters.
        let arguments: [Any?] = [path.rawValue, prefix.unicodeScalars.count, prefix]
        let removed = try db.rows("SELECT \(columns) FROM items WHERE \(condition)", arguments, decode)
        try db.run("DELETE FROM items WHERE \(condition)", arguments)
        return removed
    }
}

// MARK: - Minimal SQLite wrapper

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Only used under the store's mutex, hence the
/// unchecked conformance.
final class Connection: @unchecked Sendable {
    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw PlumeError.invalidResponse("database: " + String(cString: sqlite3_errmsg(db)))
        }
        // The app and an extension may write at the same time.
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func run(_ sql: String, _ arguments: [Any?]) throws {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func rows<T>(_ sql: String, _ arguments: [Any?], _ decode: (Row) -> T) throws -> [T] {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(decode(Row(statement: statement)))
            case SQLITE_DONE: return result
            default: throw error()
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ arguments: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case nil: sqlite3_bind_null(statement, index)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as Bool: sqlite3_bind_int64(statement, index, value ? 1 : 0)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func error() -> PlumeError {
        .invalidResponse("database: " + String(cString: sqlite3_errmsg(db)))
    }
}

struct Row {
    let statement: OpaquePointer?

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

    func double(_ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
    }
}
