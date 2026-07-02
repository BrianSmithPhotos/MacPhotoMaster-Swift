import Foundation
import GRDB

/// Persisted per-folder skip state: a file (or every member of a capture set, one row each)
/// hidden from the current session view. Persisted so a re-opened folder remembers what was
/// skipped — see docs/SPEC.md §1. "Skip" only ever hides from view; it never touches the file on
/// disk (see docs/SPEC.md's "Non-destructive SD card workflow").
///
/// Stored in Application Support rather than written into the source folder: the source is often
/// a temporary SD card mount, and skip state needs to survive after the card's ejected/reformatted
/// and reused for the next shoot. Same GRDB-actor shape as `TimelineLocationCache` — see that
/// file's doc comment and docs/ARCHITECTURE.md "Local cache" for why GRDB over SwiftData here.
actor SkipStateStore {
    private let dbQueue: DatabaseQueue

    init(databasePath: URL) throws {
        try FileManager.default.createDirectory(
            at: databasePath.deletingLastPathComponent(), withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        dbQueue = try DatabaseQueue(path: databasePath.path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createSkippedAssetTable") { db in
            try db.create(table: "skippedAsset") { table in
                table.column("folderPath", .text).notNull()
                table.column("assetPath", .text).notNull()
                table.column("skippedAt", .datetime).notNull()
                table.primaryKey(["folderPath", "assetPath"])
            }
        }
        return migrator
    }

    /// Marks each path as skipped for this folder. Idempotent — re-skipping an already-skipped
    /// path just refreshes its timestamp rather than erroring or duplicating the row.
    func skip(assetPaths: [String], inFolder folderPath: String) throws {
        try dbQueue.write { db in
            for assetPath in assetPaths {
                try db.execute(
                    sql: """
                        INSERT INTO skippedAsset (folderPath, assetPath, skippedAt) VALUES (?, ?, ?)
                        ON CONFLICT(folderPath, assetPath) DO UPDATE SET skippedAt = excluded.skippedAt
                        """,
                    arguments: [folderPath, assetPath, Date()])
            }
        }
    }

    /// Restores previously-skipped paths to the session view.
    func unskip(assetPaths: [String], inFolder folderPath: String) throws {
        try dbQueue.write { db in
            for assetPath in assetPaths {
                try db.execute(
                    sql: "DELETE FROM skippedAsset WHERE folderPath = ? AND assetPath = ?",
                    arguments: [folderPath, assetPath])
            }
        }
    }

    /// Every path currently skipped within this folder — checked when a folder is (re-)loaded so
    /// previously-skipped files/capture sets stay hidden across app launches. Scoped to
    /// `folderPath` (rather than one global skipped-paths table) so the same filename in two
    /// different folders doesn't cross-contaminate skip state.
    func skippedAssetPaths(inFolder folderPath: String) throws -> Set<String> {
        try dbQueue.read { db in
            let paths = try String.fetchAll(
                db, sql: "SELECT assetPath FROM skippedAsset WHERE folderPath = ?", arguments: [folderPath])
            return Set(paths)
        }
    }
}
