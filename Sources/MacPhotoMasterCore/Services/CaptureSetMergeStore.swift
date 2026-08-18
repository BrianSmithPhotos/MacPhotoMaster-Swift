import Foundation
import GRDB

/// Persisted per-folder record of capture sets the user merged by hand, so the merge survives
/// reopening the folder. One row per file, carrying the id of the merge it belongs to — see
/// `CaptureSetMerging` for why the key is the file path and not the set id.
///
/// Stored in Application Support for the same reason as `SkipStateStore`: the source folder is
/// often an SD card that will be reformatted, and this is the user's editorial judgement about the
/// shoot, which should outlive the card.
public actor CaptureSetMergeStore {
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
        migrator.registerMigration("createMergedAssetTable") { db in
            try db.create(table: "mergedAsset") { table in
                table.column("folderPath", .text).notNull()
                table.column("assetPath", .text).notNull()
                table.column("mergeID", .text).notNull()
                table.column("mergedAt", .datetime).notNull()
                table.primaryKey(["folderPath", "assetPath"])
            }
        }
        return migrator
    }

    /// Records every given path as belonging to one merge, and returns that merge's id.
    ///
    /// Paths already in another merge are moved into this one, which is what makes merging a
    /// selection that includes an existing merged set absorb it rather than fail.
    @discardableResult
    public func merge(assetPaths: [String], inFolder folderPath: String) throws -> String {
        let mergeID = UUID().uuidString
        try dbQueue.write { db in
            for assetPath in assetPaths {
                try db.execute(
                    sql: """
                        INSERT INTO mergedAsset (folderPath, assetPath, mergeID, mergedAt)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(folderPath, assetPath)
                        DO UPDATE SET mergeID = excluded.mergeID, mergedAt = excluded.mergedAt
                        """,
                    arguments: [folderPath, assetPath, mergeID, Date()])
            }
        }
        return mergeID
    }

    /// Drops the given paths out of whatever merge they were in, so grouping's own answer stands
    /// again — the inverse of `merge(assetPaths:inFolder:)`.
    public func unmerge(assetPaths: [String], inFolder folderPath: String) throws {
        try dbQueue.write { db in
            for assetPath in assetPaths {
                try db.execute(
                    sql: "DELETE FROM mergedAsset WHERE folderPath = ? AND assetPath = ?",
                    arguments: [folderPath, assetPath])
            }
        }
    }

    /// Every merged path in this folder, mapped to its merge id — read once per folder load and
    /// handed straight to `CaptureSetMerging.apply(_:mergeIDsByAssetPath:)`.
    public func mergeIDsByAssetPath(inFolder folderPath: String) throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT assetPath, mergeID FROM mergedAsset WHERE folderPath = ?",
                arguments: [folderPath])
            return Dictionary(
                uniqueKeysWithValues: rows.map { ($0["assetPath"] as String, $0["mergeID"] as String) })
        }
    }
}
