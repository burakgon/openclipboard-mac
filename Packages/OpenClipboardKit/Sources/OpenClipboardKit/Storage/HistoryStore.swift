import Foundation

/// The clipboard history, in one SQLite file.
///
/// Rows are small and listed often; payloads and thumbnails live in their own tables and are
/// read only when a clip is shown large or pasted. Being an actor, the store does all of its
/// work off the main thread and one call at a time.
public actor HistoryStore {
    /// What happened to the history. Observers reload on any of these.
    public enum Change: Sendable, Equatable {
        /// A clip was added, or an existing one was copied again and moved to the front.
        case recorded(id: Int64, isNew: Bool)
        /// A clip was pinned, unpinned or moved to the front.
        case updated(id: Int64)
        /// One or more clips were deleted or pruned.
        case removed
    }

    public struct Statistics: Sendable, Equatable {
        public var clipCount: Int
        public var pinnedCount: Int
        /// Bytes the database occupies on disk.
        public var diskBytes: Int
    }

    private let database: Database
    private let fileURL: URL?
    private var observers: [UUID: AsyncStream<Change>.Continuation] = [:]

    /// Opens the history at `fileURL`, creating it and its folder when needed.
    public init(fileURL: URL) throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        database = try Database(path: fileURL.path)
        self.fileURL = fileURL
        // Readable by this user only. The write-ahead log inherits the mode of the main file.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try Self.configure(database)
        try Self.migrate(database)
    }

    /// A history that lives in memory, for tests and previews.
    public init() throws {
        database = try Database(path: ":memory:")
        fileURL = nil
        try Self.configure(database)
        try Self.migrate(database)
    }

    // MARK: - Schema

    private static func configure(_ database: Database) throws {
        // auto_vacuum has to be chosen before the first table exists.
        try database.execute("""
            PRAGMA auto_vacuum = INCREMENTAL;
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA secure_delete = ON;
            PRAGMA temp_store = MEMORY;
            PRAGMA cache_size = -1024;
            PRAGMA journal_size_limit = 4194304;
            """)
    }

    private static func migrate(_ database: Database) throws {
        let version = try database.scalar("PRAGMA user_version")
        if version < 1 {
            try database.transaction {
                // search_text comes last: it can be long, and listing clips never reads it.
                try database.execute("""
                    CREATE TABLE clip (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        kind INTEGER NOT NULL,
                        created_at REAL NOT NULL,
                        used_at REAL NOT NULL,
                        pinned_at REAL,
                        hash BLOB NOT NULL UNIQUE,
                        app_bundle_id TEXT,
                        app_name TEXT,
                        byte_size INTEGER NOT NULL,
                        copy_count INTEGER NOT NULL DEFAULT 1,
                        title TEXT NOT NULL,
                        meta TEXT NOT NULL,
                        search_text TEXT NOT NULL
                    );
                    CREATE INDEX clip_by_use ON clip (used_at DESC);
                    CREATE INDEX clip_by_pin ON clip (pinned_at DESC) WHERE pinned_at IS NOT NULL;
                    CREATE TABLE representation (
                        id INTEGER PRIMARY KEY,
                        clip_id INTEGER NOT NULL REFERENCES clip (id) ON DELETE CASCADE,
                        item INTEGER NOT NULL,
                        ord INTEGER NOT NULL,
                        type TEXT NOT NULL,
                        data BLOB NOT NULL
                    );
                    CREATE INDEX representation_by_clip ON representation (clip_id, item, ord);
                    CREATE TABLE thumbnail (
                        clip_id INTEGER PRIMARY KEY REFERENCES clip (id) ON DELETE CASCADE,
                        data BLOB NOT NULL
                    );
                    PRAGMA user_version = 1;
                    """)
            }
        }
    }

    // MARK: - Observing

    /// A stream of changes, for as long as the caller keeps iterating it.
    public func changes() -> AsyncStream<Change> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Change.self, bufferingPolicy: .bufferingNewest(32))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify(_ change: Change) {
        for continuation in observers.values { continuation.yield(change) }
    }

    // MARK: - Writing

    /// Stores a captured clip. Content that is already in the history is not stored twice:
    /// the existing clip moves to the front and its copy count goes up.
    @discardableResult
    public func record(_ draft: ClipDraft, at date: Date = Date()) throws -> ClipItem {
        let meta = String(decoding: (try? JSONEncoder().encode(draft.meta)) ?? Data("{}".utf8), as: UTF8.self)
        let (id, isNew) = try database.transaction { () -> (Int64, Bool) in
            let existing = try database.query("SELECT id FROM clip WHERE hash = ?", [.blob(draft.hash)]) { $0.integer(0) }
            if let id = existing.first {
                // The same content again. The newest copy wins: the same words may now come
                // with other formatting, and what is stored should be what ⌘V would paste.
                try database.run("""
                    UPDATE clip SET used_at = ?, copy_count = copy_count + 1, kind = ?, byte_size = ?,
                        title = ?, meta = ?, search_text = ?,
                        app_bundle_id = COALESCE(?, app_bundle_id), app_name = COALESCE(?, app_name)
                    WHERE id = ?
                    """, [
                        .date(date), .integer(Int64(draft.kind.rawValue)), .integer(Int64(draft.byteSize)),
                        .text(draft.title), .text(meta), .text(draft.searchText),
                        .optional(draft.appBundleID), .optional(draft.appName), .integer(id),
                    ])
                // A picture's hash covers all of its bytes: there is nothing new to store.
                if draft.kind != .image {
                    try database.run("DELETE FROM representation WHERE clip_id = ?", [.integer(id)])
                    try insertContents(draft.contents, clipID: id)
                }
                return (id, false)
            }

            try database.run("""
                INSERT INTO clip (kind, created_at, used_at, hash, app_bundle_id, app_name, byte_size, title, meta, search_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .integer(Int64(draft.kind.rawValue)), .date(date), .date(date), .blob(draft.hash),
                    .optional(draft.appBundleID), .optional(draft.appName), .integer(Int64(draft.byteSize)),
                    .text(draft.title), .text(meta), .text(draft.searchText),
                ])
            let id = database.lastInsertRowID
            try insertContents(draft.contents, clipID: id)
            if let thumbnail = draft.thumbnail {
                try database.run("INSERT INTO thumbnail (clip_id, data) VALUES (?, ?)", [.integer(id), .blob(thumbnail)])
            }
            return (id, true)
        }
        notify(.recorded(id: id, isNew: isNew))
        guard let item = try item(id: id) else {
            throw DatabaseError(code: 0, message: "the clip that was just stored is missing")
        }
        return item
    }

    private func insertContents(_ contents: ClipContents, clipID: Int64) throws {
        for (itemIndex, item) in contents.enumerated() {
            for (order, representation) in item.enumerated() {
                try database.run(
                    "INSERT INTO representation (clip_id, item, ord, type, data) VALUES (?, ?, ?, ?, ?)",
                    [.integer(clipID), .integer(Int64(itemIndex)), .integer(Int64(order)),
                     .text(representation.type), .blob(representation.data)])
            }
        }
    }

    /// Pins or unpins a clip. Pinned clips survive pruning and clearing.
    public func setPinned(_ pinned: Bool, id: Int64, at date: Date = Date()) throws {
        let changed = try database.run(
            "UPDATE clip SET pinned_at = ? WHERE id = ?", [pinned ? .date(date) : .null, .integer(id)])
        if changed > 0 { notify(.updated(id: id)) }
    }

    /// Moves a clip to the front of the history, as when it is pasted.
    public func touch(id: Int64, at date: Date = Date()) throws {
        let changed = try database.run("UPDATE clip SET used_at = ? WHERE id = ?", [.date(date), .integer(id)])
        if changed > 0 { notify(.updated(id: id)) }
    }

    public func delete(id: Int64) throws {
        let changed = try database.run("DELETE FROM clip WHERE id = ?", [.integer(id)])
        if changed > 0 {
            reclaimSpace()
            notify(.removed)
        }
    }

    /// Deletes the whole history. Pinned clips are kept unless `includingPinned` is set.
    public func clear(includingPinned: Bool = false) throws {
        try database.run(includingPinned ? "DELETE FROM clip" : "DELETE FROM clip WHERE pinned_at IS NULL")
        reclaimSpace()
        notify(.removed)
    }

    /// Deletes clips that are not pinned and were last used before `cutoff`, then, when
    /// `limit` is given, the oldest ones beyond that many. Returns how many were deleted.
    @discardableResult
    public func prune(olderThan cutoff: Date? = nil, keepingAtMost limit: Int? = nil) throws -> Int {
        var deleted = 0
        if let cutoff {
            deleted += try database.run(
                "DELETE FROM clip WHERE pinned_at IS NULL AND used_at < ?", [.date(cutoff)])
        }
        if let limit {
            deleted += try database.run("""
                DELETE FROM clip WHERE pinned_at IS NULL AND id NOT IN (
                    SELECT id FROM clip WHERE pinned_at IS NULL ORDER BY used_at DESC, id DESC LIMIT ?
                )
                """, [.integer(Int64(max(limit, 0)))])
        }
        if deleted > 0 {
            reclaimSpace()
            notify(.removed)
        }
        return deleted
    }

    /// Hands the pages of deleted clips back to the file system.
    private func reclaimSpace() {
        try? database.execute("PRAGMA incremental_vacuum; PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Reading

    private static let columns =
        "id, kind, created_at, used_at, pinned_at, app_bundle_id, app_name, byte_size, copy_count, title, meta"

    private static func decode(_ row: Database.Row) -> ClipItem {
        let meta = row.text(10).flatMap { try? JSONDecoder().decode(ClipMeta.self, from: Data($0.utf8)) }
        return ClipItem(
            id: row.integer(0),
            kind: ClipKind(rawValue: Int(row.integer(1))) ?? .text,
            createdAt: row.date(2) ?? .distantPast,
            usedAt: row.date(3) ?? .distantPast,
            pinnedAt: row.date(4),
            title: row.text(9) ?? "",
            meta: meta ?? ClipMeta(),
            appBundleID: row.text(5),
            appName: row.text(6),
            byteSize: Int(row.integer(7)),
            copyCount: Int(row.integer(8))
        )
    }

    private static func filter(for query: ClipQuery) -> (clause: String, values: [SQLValue]) {
        var conditions: [String] = []
        var values: [SQLValue] = []
        if let kind = query.kind {
            conditions.append("kind = ?")
            values.append(.integer(Int64(kind.rawValue)))
        }
        if query.pinnedOnly {
            conditions.append("pinned_at IS NOT NULL")
        }
        for term in TextAnalysis.searchTerms(in: query.text) {
            conditions.append("instr(search_text, ?) > 0")
            values.append(.text(term))
        }
        return (conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "), values)
    }

    /// Lists clips, most recently used first. With `pinnedOnly`, most recently pinned first.
    public func items(matching query: ClipQuery = ClipQuery(), limit: Int = 60, offset: Int = 0) throws -> [ClipItem] {
        let (clause, values) = Self.filter(for: query)
        let order = query.pinnedOnly ? "pinned_at DESC, id DESC" : "used_at DESC, id DESC"
        return try database.query(
            "SELECT \(Self.columns) FROM clip \(clause) ORDER BY \(order) LIMIT ? OFFSET ?",
            values + [.integer(Int64(limit)), .integer(Int64(offset))],
            Self.decode)
    }

    public func count(matching query: ClipQuery = ClipQuery()) throws -> Int {
        let (clause, values) = Self.filter(for: query)
        return Int(try database.scalar("SELECT COUNT(*) FROM clip \(clause)", values))
    }

    public func item(id: Int64) throws -> ClipItem? {
        try database.query("SELECT \(Self.columns) FROM clip WHERE id = ?", [.integer(id)], Self.decode).first
    }

    /// Everything that was on the pasteboard for this clip, ready to be written back.
    public func contents(of id: Int64) throws -> ClipContents {
        let rows = try database.query(
            "SELECT item, type, data FROM representation WHERE clip_id = ? ORDER BY item, ord", [.integer(id)]
        ) { row in
            (item: row.integer(0), representation: ClipRepresentation(type: row.text(1) ?? "", data: row.blob(2) ?? Data()))
        }
        var contents: ClipContents = []
        var currentItem: Int64 = -1
        for row in rows {
            if row.item != currentItem {
                currentItem = row.item
                contents.append([])
            }
            contents[contents.count - 1].append(row.representation)
        }
        return contents
    }

    /// The data stored under one type of the clip's first item, or nil.
    public func data(of id: Int64, type: String) throws -> Data? {
        try database.query(
            "SELECT data FROM representation WHERE clip_id = ? AND type = ? ORDER BY item, ord LIMIT 1",
            [.integer(id), .text(type)]
        ) { $0.blob(0) ?? Data() }.first
    }

    /// The type identifiers stored for the clip's first item, richest first.
    public func types(of id: Int64) throws -> [String] {
        try database.query(
            "SELECT type FROM representation WHERE clip_id = ? AND item = 0 ORDER BY ord", [.integer(id)]
        ) { $0.text(0) ?? "" }
    }

    public func thumbnail(of id: Int64) throws -> Data? {
        try database.query("SELECT data FROM thumbnail WHERE clip_id = ?", [.integer(id)]) { $0.blob(0) ?? Data() }.first
    }

    public func statistics() throws -> Statistics {
        let clips = Int(try database.scalar("SELECT COUNT(*) FROM clip"))
        let pinned = Int(try database.scalar("SELECT COUNT(*) FROM clip WHERE pinned_at IS NOT NULL"))
        let pages = try database.scalar("PRAGMA page_count") - (try database.scalar("PRAGMA freelist_count"))
        let pageSize = try database.scalar("PRAGMA page_size")
        return Statistics(clipCount: clips, pinnedCount: pinned, diskBytes: Int(pages * pageSize))
    }
}
