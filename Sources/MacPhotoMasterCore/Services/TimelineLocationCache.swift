import Foundation
import GRDB

/// Local SQLite-backed cache of Google Timeline position samples, providing bounded
/// nearest-timestamp GPS matching for photo capture times. Mirrors the reference app's
/// `TimelineLocationService` (see docs/SPEC.md §7) but only owns the cache/query half — parsing a
/// raw Timeline JSON export into `TimelineSample` values is a separate concern for whoever calls
/// `importSamples`.
///
/// Uses GRDB rather than SwiftData: the nearest-timestamp-within-a-window query with a
/// source-reliability tie-break doesn't map cleanly onto SwiftData's `#Predicate` macros, and this
/// schema is a near-literal port of the reference app's existing SQLite cache.
public actor TimelineLocationCache {
    public static let defaultMaxMatchSeconds = 30 * 60

    private let dbQueue: DatabaseQueue
    private let maxMatchSeconds: Int

    public init(databasePath: URL, maxMatchSeconds: Int = TimelineLocationCache.defaultMaxMatchSeconds) throws {
        self.maxMatchSeconds = maxMatchSeconds
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
        migrator.registerMigration("createTimelineTables") { db in
            try db.create(table: "timelineImport") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("sourcePath", .text).notNull()
                table.column("sourceSize", .integer).notNull()
                table.column("sourceModificationNanoseconds", .integer).notNull()
                table.column("sourceSHA256", .text).notNull()
                table.column("importedAt", .datetime).notNull()
            }
            try db.create(table: "timelinePosition") { table in
                table.primaryKey("recordKey", .text)
                table.column("timestampUTC", .integer).notNull().indexed()
                table.column("latitude", .double).notNull()
                table.column("longitude", .double).notNull()
                table.column("altitudeMeters", .double)
                table.column("accuracyMeters", .double)
                table.column("sourceType", .text).notNull()
                table.column("importID", .integer).notNull()
                    .references("timelineImport", column: "id")
            }
        }
        return migrator
    }

    /// True when no prior import matches this exact source-file signature — mirrors the
    /// reference app's idempotent-import check via `timeline_imports` signature rows, so
    /// re-importing an unchanged Timeline export is a no-op.
    public func isImportNeeded(
        sourcePath: String, sourceSize: Int, sourceModificationNanoseconds: Int64
    ) throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM timelineImport
                    WHERE sourcePath = ? AND sourceSize = ? AND sourceModificationNanoseconds = ?
                    """,
                arguments: [sourcePath, sourceSize, sourceModificationNanoseconds])
            return count == 0
        }
    }

    /// Records one import event and upserts its position samples in one transaction, keyed by
    /// each sample's `recordKey` so re-imports of the same Timeline export update rows in place
    /// instead of duplicating them.
    public func importSamples(
        _ samples: [TimelineSample],
        sourcePath: String,
        sourceSize: Int,
        sourceModificationNanoseconds: Int64,
        sourceSHA256: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO timelineImport (
                        sourcePath, sourceSize, sourceModificationNanoseconds, sourceSHA256, importedAt
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [sourcePath, sourceSize, sourceModificationNanoseconds, sourceSHA256, Date()]
            )
            let importID = db.lastInsertedRowID

            for sample in samples {
                try db.execute(
                    sql: """
                        INSERT INTO timelinePosition (
                            recordKey, timestampUTC, latitude, longitude,
                            altitudeMeters, accuracyMeters, sourceType, importID
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(recordKey) DO UPDATE SET
                            timestampUTC = excluded.timestampUTC,
                            latitude = excluded.latitude,
                            longitude = excluded.longitude,
                            altitudeMeters = excluded.altitudeMeters,
                            accuracyMeters = excluded.accuracyMeters,
                            sourceType = excluded.sourceType,
                            importID = excluded.importID
                        """,
                    arguments: [
                        sample.recordKey, sample.timestampUTC, sample.latitude, sample.longitude,
                        sample.altitudeMeters, sample.accuracyMeters, sample.sourceType, importID,
                    ])
            }
        }
    }

    /// Nearest-timestamp GPS match within the configured bounded window, tie-broken by source
    /// reliability (GPS > WIFI > WIFI_ONLY > TIMELINE_PATH > other) then reported accuracy —
    /// matches the reference app's `suggest_for_capture` ordering exactly. No match within the
    /// window returns nil; callers must never guess a GPS position outside it (see docs/SPEC.md §7).
    public func suggestion(forCaptureTimestampUTC captureTimestampUTC: Int) throws -> GPSSuggestion? {
        try dbQueue.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT
                            timestampUTC, latitude, longitude, altitudeMeters, sourceType, accuracyMeters,
                            ABS(timestampUTC - ?) AS ageSeconds
                        FROM timelinePosition
                        WHERE timestampUTC BETWEEN ? AND ?
                        ORDER BY
                            ageSeconds ASC,
                            CASE sourceType
                                WHEN 'GPS' THEN 0
                                WHEN 'WIFI' THEN 1
                                WHEN 'WIFI_ONLY' THEN 2
                                WHEN 'TIMELINE_PATH' THEN 3
                                ELSE 4
                            END ASC,
                            CASE WHEN accuracyMeters IS NULL THEN 1 ELSE 0 END ASC,
                            accuracyMeters ASC
                        LIMIT 1
                        """,
                    arguments: [
                        captureTimestampUTC,
                        captureTimestampUTC - maxMatchSeconds,
                        captureTimestampUTC + maxMatchSeconds,
                    ])
            else {
                return nil
            }
            return GPSSuggestion(
                latitude: row["latitude"],
                longitude: row["longitude"],
                altitudeMeters: row["altitudeMeters"],
                sourceType: row["sourceType"],
                accuracyMeters: row["accuracyMeters"],
                matchedTimestampUTC: row["timestampUTC"],
                ageSeconds: row["ageSeconds"]
            )
        }
    }

    /// Total cached position rows — a test/debug helper, not part of the matching API.
    public func positionCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM timelinePosition") ?? 0
        }
    }
}
