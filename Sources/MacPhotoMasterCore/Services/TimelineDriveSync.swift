import Foundation

/// Copies a fresher `Timeline.json` from Google Drive over the local working copy, mirroring the
/// reference app's `TimelineSyncService` (see docs/SPEC.md §7) — no settings UI for the Drive/local
/// paths themselves, but the check now runs on every launch *and* folder open/navigate
/// (`SourceBrowserViewModel.load(_:)`), plus on demand via the "Refresh Timeline" button
/// (`SourceBrowserViewModel.refreshTimeline()`), so replacing `Timeline.json` mid-session doesn't
/// require a relaunch. Path resolution is split from the copy itself so it's unit-testable without
/// touching `~/Library/CloudStorage`.
public enum TimelineDriveSync {
    private static let driveGlobDirectoryPrefix = "GoogleDrive-"
    private static let driveGlobSuffixComponents = ["My Drive", "AI", "Gps", "Timeline.json"]

    /// The source file in Google Drive, or `nil` if neither the env override nor the Drive glob
    /// resolves to anything. `MACPHOTOMASTER_DRIVE_TIMELINE_PATH` overrides the default glob search
    /// under `~/Library/CloudStorage/GoogleDrive-*/My Drive/AI/Gps/Timeline.json`.
    // Google Drive Desktop (the source of `~/Library/CloudStorage/GoogleDrive-*`) is a macOS-only
    // app, so this default has no iOS equivalent — an unreachable path there just makes the
    // `contentsOfDirectory` lookup below fail closed, matching "Drive not mounted" on the Mac.
    #if os(macOS)
    public static let defaultCloudStorageDirectory =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
    #else
    public static let defaultCloudStorageDirectory = URL(fileURLWithPath: "/nonexistent")
    #endif

    public static func resolveDriveSourcePath(
        cloudStorageDirectory: URL = TimelineDriveSync.defaultCloudStorageDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let override = environment["MACPHOTOMASTER_DRIVE_TIMELINE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }

        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: cloudStorageDirectory, includingPropertiesForKeys: nil)
        else {
            return nil
        }
        let driveDirectories = entries
            .filter { $0.lastPathComponent.hasPrefix(driveGlobDirectoryPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for directory in driveDirectories {
            var candidate = directory
            for component in driveGlobSuffixComponents {
                candidate.appendPathComponent(component)
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// The local working copy `TimelineLocationCache` imports from. `MACPHOTOMASTER_TIMELINE_PATH`
    /// overrides the default (`AppSupportDirectory`-relative) path.
    public static func resolveLocalCopyPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let override = environment["MACPHOTOMASTER_TIMELINE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return try AppSupportDirectory.url(forFileNamed: "Timeline.json")
    }

    /// Copies `driveSource` over `localCopy` when `driveSource` exists and is newer (or `localCopy`
    /// doesn't exist yet). Returns whether a copy happened.
    @discardableResult
    public static func syncIfNewer(driveSource: URL, localCopy: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: driveSource.path) else { return false }

        if FileManager.default.fileExists(atPath: localCopy.path) {
            let driveModified = try modificationDate(of: driveSource)
            let localModified = try modificationDate(of: localCopy)
            guard driveModified > localModified else { return false }
            try FileManager.default.removeItem(at: localCopy)
        } else {
            try FileManager.default.createDirectory(
                at: localCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        try FileManager.default.copyItem(at: driveSource, to: localCopy)
        return true
    }

    private static func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.modificationDate] as? Date) ?? .distantPast
    }
}
