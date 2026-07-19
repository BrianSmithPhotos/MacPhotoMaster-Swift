import Foundation
import GRDB

/// Local cache for `EBirdSpeciesListService`'s two expensive-to-refetch lookups — see
/// `AISuggestionService`'s doc comment for why this exists at all (a verified local species list
/// beats free recall for fixing fabricated Latin binomials). Same GRDB-actor shape as
/// `ElevationCache`/`TimelineLocationCache`. Unlike `ElevationCache`, both tables here go stale
/// (eBird's taxonomy is revised roughly annually; a region's recorded species list changes as new
/// observations are logged), so callers pass a max age and compare against the returned
/// `fetchedAt` themselves — this actor only stores/reads, it doesn't decide what's "too old".
public actor EBirdCache {
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
        migrator.registerMigration("createEBirdTables") { db in
            try db.create(table: "ebirdTaxonomy") { table in
                table.column("speciesCode", .text).notNull().primaryKey()
                table.column("commonName", .text).notNull()
                table.column("scientificName", .text).notNull()
                table.column("category", .text).notNull()
            }
            try db.create(table: "ebirdTaxonomyMeta") { table in
                table.column("id", .integer).notNull().primaryKey()
                table.column("fetchedAt", .double).notNull()
            }
            try db.create(table: "ebirdRegionSpecies") { table in
                table.column("regionCode", .text).notNull().primaryKey()
                table.column("speciesCodesJSON", .text).notNull()
                table.column("fetchedAt", .double).notNull()
            }
        }
        return migrator
    }

    // MARK: - Taxonomy

    public func taxonomyFetchedAt() throws -> Date? {
        try dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT fetchedAt FROM ebirdTaxonomyMeta WHERE id = 1")
                .map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Full replace rather than an incremental upsert — eBird's taxonomy is refetched wholesale
    /// (there's no per-row delta endpoint), so a stale row for a code that's since been retired
    /// would otherwise linger forever.
    public func replaceTaxonomy(_ entries: [EBirdTaxonEntry]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM ebirdTaxonomy")
            for entry in entries {
                try db.execute(
                    sql: """
                        INSERT INTO ebirdTaxonomy (speciesCode, commonName, scientificName, category)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        entry.speciesCode, entry.commonName, entry.scientificName, entry.category,
                    ])
            }
            try db.execute(
                sql: """
                    INSERT INTO ebirdTaxonomyMeta (id, fetchedAt) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET fetchedAt = excluded.fetchedAt
                    """,
                arguments: [Date().timeIntervalSince1970])
        }
    }

    /// Looks up `speciesCodes` against the cached taxonomy — codes with no match (e.g. a stale
    /// region-species cache referencing a code dropped in a taxonomy revision) are silently
    /// omitted rather than erroring, matching this cache's general best-effort-enrichment posture.
    public func taxonomyEntries(forSpeciesCodes speciesCodes: [String]) throws -> [EBirdTaxonEntry] {
        guard !speciesCodes.isEmpty else { return [] }
        let placeholders = speciesCodes.map { _ in "?" }.joined(separator: ", ")
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT speciesCode, commonName, scientificName, category FROM ebirdTaxonomy
                    WHERE speciesCode IN (\(placeholders))
                    """,
                arguments: StatementArguments(speciesCodes))
            return rows.map {
                EBirdTaxonEntry(
                    speciesCode: $0["speciesCode"], commonName: $0["commonName"],
                    scientificName: $0["scientificName"], category: $0["category"])
            }
        }
    }

    // MARK: - Region species lists

    public func cachedSpeciesCodes(regionCode: String) throws -> (codes: [String], fetchedAt: Date)? {
        try dbQueue.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT speciesCodesJSON, fetchedAt FROM ebirdRegionSpecies WHERE regionCode = ?",
                    arguments: [regionCode])
            else { return nil }
            let json: String = row["speciesCodesJSON"]
            guard let data = json.data(using: .utf8),
                let codes = try? JSONSerialization.jsonObject(with: data) as? [String]
            else { return nil }
            let fetchedAt: Double = row["fetchedAt"]
            return (codes, Date(timeIntervalSince1970: fetchedAt))
        }
    }

    public func storeSpeciesCodes(_ codes: [String], regionCode: String) throws {
        let data = try JSONSerialization.data(withJSONObject: codes)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ebirdRegionSpecies (regionCode, speciesCodesJSON, fetchedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(regionCode) DO UPDATE SET
                        speciesCodesJSON = excluded.speciesCodesJSON, fetchedAt = excluded.fetchedAt
                    """,
                arguments: [regionCode, json, Date().timeIntervalSince1970])
        }
    }
}
