import CryptoKit
import Foundation

enum ProcessMoveError: Error, Equatable {
    case sourceNotFound(URL)
    case copySizeMismatch(source: URL, destination: URL)
    case copyChecksumMismatch(source: URL, destination: URL)
}

/// One successfully processed file: the untouched source and the verified destination copy that
/// now carries the routed/renamed filename and freshly written metadata.
struct ProcessMoveResult: Equatable {
    var sourceURL: URL
    var destinationURL: URL
}

/// Copies a source photo into its destination library folder and writes its metadata there —
/// copy-first, and the source (e.g. an SD card file) is never touched or deleted, per
/// docs/SPEC.md §5. Destination routing mirrors the reference app's `process_move_service.py`:
/// `<library>/<M Month>/<DD>/` by capture date, with JPEGs routed one level deeper into `jpg/` so a
/// RAW+JPEG pair from the same capture lands in sibling folders instead of interleaved together.
struct ProcessMoveService {
    private let exifTool: ExifToolClient
    private let renameService: RenameService

    init(exifTool: ExifToolClient = ExifToolClient(), renameService: RenameService = RenameService()) {
        self.exifTool = exifTool
        self.renameService = renameService
    }

    private static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    private static let hashChunkSize = 1024 * 1024

    /// Copies `asset.url` into its routed destination folder under `libraryRoot`, verifies the
    /// copy (size + SHA-256) before trusting it, then writes `asset`'s current title/description/
    /// keywords/GPS to the destination copy. Any failure — verification or metadata write — trashes
    /// the partial destination copy rather than leaving an unannotated or corrupt file behind, so
    /// the source stays the only trustworthy copy until a retry succeeds end-to-end.
    ///
    /// `renameContext` supplies the fields `RenameService` needs to compute the destination
    /// filename — see its doc comment for why that's a separate type from `PhotoAsset`.
    func processAndCopy(
        asset: PhotoAsset, renameContext: RenameContext, libraryRoot: URL
    ) async throws -> ProcessMoveResult {
        guard FileManager.default.fileExists(atPath: asset.url.path) else {
            throw ProcessMoveError.sourceNotFound(asset.url)
        }

        let destinationDirectory = Self.destinationDirectory(for: asset, libraryRoot: libraryRoot)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let existingNames = Self.existingFileNames(in: destinationDirectory)
        let proposedName = renameService.buildFilename(for: renameContext)
        let finalName = renameService.ensureUniqueName(proposedName, existingNames: existingNames)
        let destinationURL = destinationDirectory.appendingPathComponent(finalName)

        try FileManager.default.copyItem(at: asset.url, to: destinationURL)

        do {
            try Self.verifyCopy(source: asset.url, destination: destinationURL)
            try await exifTool.write(
                title: asset.title.isEmpty ? nil : asset.title,
                description: asset.descriptionText,
                keywords: asset.keywords,
                gps: Self.gpsCoordinate(for: asset),
                to: destinationURL)
        } catch {
            Self.discardIncompleteCopy(at: destinationURL)
            throw error
        }

        return ProcessMoveResult(sourceURL: asset.url, destinationURL: destinationURL)
    }

    private static func gpsCoordinate(for asset: PhotoAsset) -> GPSCoordinate? {
        guard let latitude = asset.gpsLatitude, let longitude = asset.gpsLongitude else { return nil }
        return GPSCoordinate(latitude: latitude, longitude: longitude, altitude: asset.gpsAltitude)
    }

    /// `<library>/<M Month>/<DD>/`, with JPEGs routed one level deeper into `jpg/` — see
    /// docs/SPEC.md §5. Falls back to the source file's filesystem modification date when
    /// `asset.capturedAt` is `nil` (e.g. exiftool couldn't read a capture timestamp at all).
    /// Internal rather than `private` so routing can be unit tested directly without needing a
    /// real exiftool-readable file for every extension this decides between.
    static func destinationDirectory(for asset: PhotoAsset, libraryRoot: URL) -> URL {
        let capturedAt = asset.capturedAt ?? modificationDate(of: asset.url)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let month = calendar.component(.month, from: capturedAt)
        let day = calendar.component(.day, from: capturedAt)

        let monthNameFormatter = DateFormatter()
        monthNameFormatter.timeZone = .current
        monthNameFormatter.dateFormat = "MMMM"

        let monthFolder = "\(month) \(monthNameFormatter.string(from: capturedAt))"
        let dayFolder = String(format: "%02d", day)
        let baseDirectory = libraryRoot.appendingPathComponent(monthFolder).appendingPathComponent(dayFolder)

        guard jpegExtensions.contains(asset.url.pathExtension.lowercased()) else { return baseDirectory }
        return baseDirectory.appendingPathComponent("jpg")
    }

    private static func modificationDate(of url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date) ?? Date()
    }

    private static func existingFileNames(in directory: URL) -> Set<String> {
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        return Set(names ?? [])
    }

    private static func verifyCopy(source: URL, destination: URL) throws {
        let sourceSize = try fileSize(at: source)
        let destinationSize = try fileSize(at: destination)
        guard sourceSize == destinationSize else {
            throw ProcessMoveError.copySizeMismatch(source: source, destination: destination)
        }
        guard try sha256(of: source) == sha256(of: destination) else {
            throw ProcessMoveError.copyChecksumMismatch(source: source, destination: destination)
        }
    }

    private static func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while true {
            let chunk = try handle.read(upToCount: hashChunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Per docs/CLAUDE.md "File Safety": deletion always goes through the trash, even for a
    /// just-created destination copy that failed verification or metadata write, never
    /// `FileManager.removeItem`.
    private static func discardIncompleteCopy(at url: URL) {
        _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
