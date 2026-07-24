import XCTest

@testable import MacPhotoMasterCore

/// Covers reading a sidecar that sits plainly beside its image — the shape the Mac app's iPad import
/// meets, as opposed to `SidecarStagingStoreTests`' filename+size-keyed staging directory. Every case
/// round-trips through the real `NativeMetadataWriter` rather than a hand-written XMP literal, so a
/// change to either side of the pair fails here.
final class SidecarDraftParsingTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// `NativeMetadataWriter.write` never reads the URL it's handed, only derives a sidecar path
    /// from it, so no real image file is needed to produce a realistic sidecar.
    private func writeSidecar(
        title: String?, description: String, keywords: [String], gps: GPSCoordinate?
    ) async throws -> URL {
        let imageURL = try makeTempDirectory().appendingPathComponent("1010042_20260621_1405_OM-1_12-40mm.orf")
        try await NativeMetadataWriter().write(
            title: title, description: description, keywords: keywords, gps: gps, to: imageURL)
        return NativeMetadataWriter.sidecarURL(for: imageURL)
    }

    func testRoundTripsAllFields() async throws {
        let sidecarURL = try await writeSidecar(
            title: "1010042_20260621_1405_OM-1_12-40mm",
            description: "Great egret stalking the shallows.",
            keywords: ["Great Egret", "Ardea alba", "OM-1"],
            gps: GPSCoordinate(latitude: 45.523, longitude: -122.676, altitude: 63))

        let draft = try XCTUnwrap(try SidecarDraftParsing.draft(at: sidecarURL))

        XCTAssertEqual(draft.title, "1010042_20260621_1405_OM-1_12-40mm")
        XCTAssertEqual(draft.description, "Great egret stalking the shallows.")
        XCTAssertEqual(draft.keywords, ["Great Egret", "Ardea alba", "OM-1"])
        let gps = try XCTUnwrap(draft.gps)
        XCTAssertEqual(gps.latitude, 45.523, accuracy: 0.00001)
        XCTAssertEqual(gps.longitude, -122.676, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(gps.altitude), 63, accuracy: 0.00001)
    }

    /// Altitude is the field `ExifToolClient.foldInSidecarIfPresent` doesn't ask for, and the reason
    /// the import reads the XMP directly instead of shelling out.
    func testRecoversFixWithoutAltitude() async throws {
        let sidecarURL = try await writeSidecar(
            title: nil, description: "", keywords: [],
            gps: GPSCoordinate(latitude: 45.523, longitude: -122.676))

        let draft = try XCTUnwrap(try SidecarDraftParsing.draft(at: sidecarURL))

        XCTAssertNil(try XCTUnwrap(draft.gps).altitude)
    }

    func testOmitsGPSEntirelyWhenNoneWasWritten() async throws {
        let sidecarURL = try await writeSidecar(
            title: nil, description: "No fix available.", keywords: ["sooc"], gps: nil)

        let draft = try XCTUnwrap(try SidecarDraftParsing.draft(at: sidecarURL))

        XCTAssertNil(draft.gps)
        XCTAssertEqual(draft.description, "No fix available.")
        XCTAssertEqual(draft.keywords, ["sooc"])
    }

    /// An empty title is written as no tag at all, so it must not come back as `""`.
    func testTreatsMissingTitleAsNil() async throws {
        let sidecarURL = try await writeSidecar(title: nil, description: "", keywords: [], gps: nil)

        XCTAssertNil(try XCTUnwrap(try SidecarDraftParsing.draft(at: sidecarURL)).title)
    }

    func testReturnsNilWhenNoSidecarExists() throws {
        let missing = try makeTempDirectory().appendingPathComponent("nothing.xmp")

        XCTAssertNil(try SidecarDraftParsing.draft(at: missing))
    }

    /// A corrupt sidecar is distinguishable from an absent one — the import reports the first and
    /// silently tolerates the second.
    func testThrowsOnUnparseableSidecar() throws {
        let sidecarURL = try makeTempDirectory().appendingPathComponent("broken.xmp")
        try Data("not xmp at all".utf8).write(to: sidecarURL)

        XCTAssertThrowsError(try SidecarDraftParsing.draft(at: sidecarURL))
    }
}
