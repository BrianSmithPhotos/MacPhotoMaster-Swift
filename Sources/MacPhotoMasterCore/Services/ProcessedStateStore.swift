import Foundation
import GRDB

/// Persisted per-folder "processed" marker: set once a file has been successfully copied via
/// `ProcessMoveService`, purely so `SourcePanelView`/`PreviewPanelView` can show an informational
/// checkmark badge. Deliberately non-blocking — this must never prevent reprocessing, only hint that
/// it already happened once. Same GRDB-actor shape as `SkipStateStore` (Application Support rather
/// than the source folder, since the source is often a temporary SD card mount) — see that file's
/// doc comment and docs/ARCHITECTURE.md "Local cache" for the GRDB-over-SwiftData rationale.
public actor ProcessedStateStore {
    private let dbQueue: DatabaseQueue

    public init(databasePath: URL) throws {
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
        migrator.registerMigration("createProcessedAssetTable") { db in
            try db.create(table: "processedAsset") { table in
                table.column("folderPath", .text).notNull()
                table.column("assetPath", .text).notNull()
                table.column("processedAt", .datetime).notNull()
                table.primaryKey(["folderPath", "assetPath"])
            }
        }
        return migrator
    }

    /// Marks each path as processed for this folder. Idempotent — reprocessing an already-processed
    /// path just refreshes its timestamp rather than erroring or duplicating the row.
    public func markProcessed(assetPaths: [String], inFolder folderPath: String) throws {
        try dbQueue.write { db in
            for assetPath in assetPaths {
                try db.execute(
                    sql: """
                        INSERT INTO processedAsset (folderPath, assetPath, processedAt) VALUES (?, ?, ?)
                        ON CONFLICT(folderPath, assetPath) DO UPDATE SET processedAt = excluded.processedAt
                        """,
                    arguments: [folderPath, assetPath, Date()])
            }
        }
    }

    /// Every path currently marked processed within this folder — checked when a folder is
    /// (re-)loaded so the checkmark badge survives across app launches. Scoped to `folderPath` like
    /// `SkipStateStore.skippedAssetPaths`, so the same filename in two different folders doesn't
    /// cross-contaminate processed state.
    public func processedAssetPaths(inFolder folderPath: String) throws -> Set<String> {
        try dbQueue.read { db in
            let paths = try String.fetchAll(
                db, sql: "SELECT assetPath FROM processedAsset WHERE folderPath = ?", arguments: [folderPath])
            return Set(paths)
        }
    }
}
