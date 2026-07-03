import Foundation
import GRDB

/// Local cache of ground-elevation lookups, keyed by coordinate rounded to 4 decimal places
/// (~11m) — see docs/SPEC.md §7: avoids a redundant USGS EPQS call for every photo in a capture set
/// shot at the same spot. Same GRDB-actor shape as `TimelineLocationCache`/`SkipStateStore`.
actor ElevationCache {
    private static let coordinatePrecision = 4

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
        migrator.registerMigration("createElevationTable") { db in
            try db.create(table: "elevation") { table in
                table.column("latitudeRounded", .double).notNull()
                table.column("longitudeRounded", .double).notNull()
                table.column("elevationMeters", .double).notNull()
                table.primaryKey(["latitudeRounded", "longitudeRounded"])
            }
        }
        return migrator
    }

    func cachedElevation(latitude: Double, longitude: Double) throws -> Double? {
        let key = Self.roundedKey(latitude: latitude, longitude: longitude)
        return try dbQueue.read { db in
            try Double.fetchOne(
                db,
                sql: """
                    SELECT elevationMeters FROM elevation
                    WHERE latitudeRounded = ? AND longitudeRounded = ?
                    """,
                arguments: [key.latitude, key.longitude])
        }
    }

    func store(latitude: Double, longitude: Double, elevationMeters: Double) throws {
        let key = Self.roundedKey(latitude: latitude, longitude: longitude)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO elevation (latitudeRounded, longitudeRounded, elevationMeters)
                    VALUES (?, ?, ?)
                    ON CONFLICT(latitudeRounded, longitudeRounded) DO UPDATE SET
                        elevationMeters = excluded.elevationMeters
                    """,
                arguments: [key.latitude, key.longitude, elevationMeters])
        }
    }

    private static func roundedKey(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        let scale = pow(10.0, Double(coordinatePrecision))
        return (latitude: (latitude * scale).rounded() / scale, longitude: (longitude * scale).rounded() / scale)
    }
}
