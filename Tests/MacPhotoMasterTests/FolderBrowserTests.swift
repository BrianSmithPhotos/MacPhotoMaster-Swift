import XCTest

@testable import MacPhotoMaster

final class FolderBrowserTests: XCTestCase {
    func testSubfoldersExcludesFilesAndHiddenEntriesAndSortsByName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let subfolders = try await FolderBrowser().subfolders(of: root)

        XCTAssertEqual(subfolders.map(\.lastPathComponent), ["A", "B"])
    }

    func testSubfoldersReturnsEmptyArrayWhenNoneExist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("hello".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let subfolders = try await FolderBrowser().subfolders(of: root)

        XCTAssertTrue(subfolders.isEmpty)
    }
}
