import Foundation

/// Resolves (and creates) this app's Application Support subdirectory — the standard macOS
/// location for local databases and other files that shouldn't sync via iCloud or clutter the
/// user's visible file browsing. Shared by `SkipStateStore` and, once wired into the app,
/// `TimelineLocationCache` — both want "a stable place on disk for a small SQLite file," not
/// anything folder- or document-specific.
public enum AppSupportDirectory {
    public static func url(forFileNamed fileName: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let appDirectory = base.appendingPathComponent("MacPhotoMaster", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory.appendingPathComponent(fileName)
    }
}
