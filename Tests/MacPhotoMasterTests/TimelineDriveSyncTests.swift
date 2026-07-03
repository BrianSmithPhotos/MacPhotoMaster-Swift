import XCTest

@testable import MacPhotoMaster

final class TimelineDriveSyncTests: XCTestCase {
    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ contents: String, to url: URL, modificationDate: Date) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
    }

    // MARK: resolveDriveSourcePath

    func testResolveDriveSourcePathPrefersEnvironmentOverride() {
        let resolved = TimelineDriveSync.resolveDriveSourcePath(
            cloudStorageDirectory: makeTempDirectory(),
            environment: ["MACPHOTOMASTER_DRIVE_TIMELINE_PATH": "/tmp/custom/Timeline.json"])

        XCTAssertEqual(resolved?.path, "/tmp/custom/Timeline.json")
    }

    func testResolveDriveSourcePathFindsGoogleDriveGlobMatch() throws {
        let cloudStorage = makeTempDirectory()
        let expected = cloudStorage
            .appendingPathComponent("GoogleDrive-someone@example.com")
            .appendingPathComponent("My Drive/AI/Gps/Timeline.json")
        try write("{}", to: expected, modificationDate: Date())

        let resolved = TimelineDriveSync.resolveDriveSourcePath(
            cloudStorageDirectory: cloudStorage, environment: [:])

        // Compare resolved paths rather than raw URLs: `/tmp`-rooted temp directories differ
        // between `/var/...` and its `/private/var/...` symlink target depending on which API
        // produced the URL, even though they name the same file.
        XCTAssertEqual(resolved?.resolvingSymlinksInPath(), expected.resolvingSymlinksInPath())
    }

    func testResolveDriveSourcePathNilWhenNoGoogleDriveDirectoryExists() {
        let resolved = TimelineDriveSync.resolveDriveSourcePath(
            cloudStorageDirectory: makeTempDirectory(), environment: [:])

        XCTAssertNil(resolved)
    }

    // MARK: resolveLocalCopyPath

    func testResolveLocalCopyPathPrefersEnvironmentOverride() throws {
        let resolved = try TimelineDriveSync.resolveLocalCopyPath(
            environment: ["MACPHOTOMASTER_TIMELINE_PATH": "/tmp/custom/local-Timeline.json"])

        XCTAssertEqual(resolved.path, "/tmp/custom/local-Timeline.json")
    }

    // MARK: syncIfNewer

    func testSyncIfNewerCopiesWhenLocalCopyMissing() throws {
        let base = makeTempDirectory()
        let driveSource = base.appendingPathComponent("drive/Timeline.json")
        let localCopy = base.appendingPathComponent("local/Timeline.json")
        try write("{\"drive\":true}", to: driveSource, modificationDate: Date())

        let copied = try TimelineDriveSync.syncIfNewer(driveSource: driveSource, localCopy: localCopy)

        XCTAssertTrue(copied)
        XCTAssertEqual(try String(contentsOf: localCopy, encoding: .utf8), "{\"drive\":true}")
    }

    func testSyncIfNewerCopiesWhenDriveFileIsNewer() throws {
        let base = makeTempDirectory()
        let driveSource = base.appendingPathComponent("drive/Timeline.json")
        let localCopy = base.appendingPathComponent("local/Timeline.json")
        try write("old", to: localCopy, modificationDate: Date(timeIntervalSince1970: 1000))
        try write("new", to: driveSource, modificationDate: Date(timeIntervalSince1970: 2000))

        let copied = try TimelineDriveSync.syncIfNewer(driveSource: driveSource, localCopy: localCopy)

        XCTAssertTrue(copied)
        XCTAssertEqual(try String(contentsOf: localCopy, encoding: .utf8), "new")
    }

    func testSyncIfNewerSkipsWhenLocalCopyIsAlreadyCurrent() throws {
        let base = makeTempDirectory()
        let driveSource = base.appendingPathComponent("drive/Timeline.json")
        let localCopy = base.appendingPathComponent("local/Timeline.json")
        try write("old", to: driveSource, modificationDate: Date(timeIntervalSince1970: 1000))
        try write("current", to: localCopy, modificationDate: Date(timeIntervalSince1970: 2000))

        let copied = try TimelineDriveSync.syncIfNewer(driveSource: driveSource, localCopy: localCopy)

        XCTAssertFalse(copied)
        XCTAssertEqual(try String(contentsOf: localCopy, encoding: .utf8), "current")
    }

    func testSyncIfNewerFalseWhenDriveSourceDoesNotExist() throws {
        let base = makeTempDirectory()
        let driveSource = base.appendingPathComponent("drive/Timeline.json")
        let localCopy = base.appendingPathComponent("local/Timeline.json")

        let copied = try TimelineDriveSync.syncIfNewer(driveSource: driveSource, localCopy: localCopy)

        XCTAssertFalse(copied)
    }
}
