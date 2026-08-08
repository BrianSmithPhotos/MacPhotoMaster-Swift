import Foundation

public enum ProcessMoveError: Error, Equatable {
    case sourceNotFound(URL)
    case copySizeMismatch(source: URL, destination: URL)
    case copyChecksumMismatch(source: URL, destination: URL)
}

/// One successfully processed file: the untouched source and the verified destination copy that
/// now carries the routed/renamed filename and freshly written metadata.
public struct ProcessMoveResult: Equatable {
    public var sourceURL: URL
    public var destinationURL: URL
}

/// Copies a source photo into its destination library folder and writes its metadata there —
/// copy-first, and the source (e.g. an SD card file) is never touched or deleted, per
/// docs/SPEC.md §5. Destination routing mirrors the reference app's `process_move_service.py`:
/// `<library>/<M Month>/<DD>/` by capture date, with JPEGs routed one level deeper into `jpg/` so a
/// RAW+JPEG pair from the same capture lands in sibling folders instead of interleaved together.
public struct ProcessMoveService {
    private let metadataWriter: any MetadataWriter
    private let renameService: RenameService

    public init(metadataWriter: any MetadataWriter, renameService: RenameService = RenameService()) {
        self.metadataWriter = metadataWriter
        self.renameService = renameService
    }

    private static let jpegExtensions: Set<String> = ["jpg", "jpeg"]

    /// Copies `asset.url` into its routed destination folder under `libraryRoot`, verifies the
    /// copy (size + SHA-256) before trusting it, then writes the destination copy's title/
    /// description/keywords/GPS. Title is never taken from `asset.title` — per the Python reference
    /// app's `process_batch_mover.py`, it's derived from the rename candidate's stem (the same name
    /// shown live as the UI's title preview), which is the only place title is ever actually written
    /// to a file. Any failure — verification or metadata write — trashes the partial destination
    /// copy rather than leaving an unannotated or corrupt file behind, so the source stays the only
    /// trustworthy copy until a retry succeeds end-to-end.
    ///
    /// `renameContext` supplies the fields `RenameService` needs to compute the destination
    /// filename — see its doc comment for why that's a separate type from `PhotoAsset`.
    public func processAndCopy(
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

        // Copied to a hidden staging name and renamed into place only once the metadata is written,
        // rather than landing at the final name and being annotated in place. A file at its real
        // name is immediately visible to anything watching the library folder, and DxO PhotoLab was
        // observed indexing one in that window and caching it with Title and Instructions still
        // empty (they are the only two fields not already present on the source), then continuing to
        // show that stale copy after the write landed. The rename is within one directory, so it is
        // atomic and no watcher ever sees a half-annotated file.
        let stagingURL = destinationDirectory.appendingPathComponent(
            ".mpm-staging-\(UUID().uuidString).\(asset.url.pathExtension)")

        try FileManager.default.copyItem(at: asset.url, to: stagingURL)

        let title = (proposedName as NSString).deletingPathExtension

        let soocToken = AutoMetadataRules.soocToken(for: asset)
        let description = AutoMetadataRules.descriptionWithArtFilterNote(
            asset.descriptionText, artFilterToken: asset.artFilterToken)
        let keywords = AutoMetadataRules.keywordsWithAutoTokens(
            asset.keywords, artFilterToken: asset.artFilterToken, cameraToken: asset.cameraModel,
            lensToken: asset.lensModel, soocToken: soocToken)
        let subjectDistance = MetadataWriteFieldRules.subjectDistanceMeters(from: asset.focusDistance)

        do {
            try Self.verifyCopy(source: asset.url, destination: stagingURL)
            try await metadataWriter.write(
                title: title,
                description: description,
                keywords: keywords,
                gps: Self.gpsCoordinate(for: asset),
                subjectDistance: subjectDistance,
                instructions: asset.cameraLook.isEmpty ? nil : asset.cameraLook,
                to: stagingURL)
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
            Self.moveSidecarIfPresent(from: stagingURL, to: destinationURL)
        } catch {
            Self.discardIncompleteCopy(at: stagingURL)
            Self.discardIncompleteCopy(at: NativeMetadataWriter.sidecarURL(for: stagingURL))
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
    public static func destinationDirectory(for asset: PhotoAsset, libraryRoot: URL) -> URL {
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
        guard try FileHashing.sha256(of: source) == FileHashing.sha256(of: destination) else {
            throw ProcessMoveError.copyChecksumMismatch(source: source, destination: destination)
        }
    }

    private static func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }

    /// On iPad there's no exiftool, so `NativeMetadataWriter` puts the metadata in a `.xmp` sidecar
    /// named after the file it belongs to (see its `sidecarURL(for:)`). Staging renames that file,
    /// so the sidecar has to follow — otherwise it keeps the staging basename and
    /// `ExifToolClient.foldInSidecarIfPresent(for:)` would never find it Mac-side. No-op on the Mac
    /// path, which writes into the file itself and produces no sidecar.
    private static func moveSidecarIfPresent(from stagingURL: URL, to destinationURL: URL) {
        let stagedSidecar = NativeMetadataWriter.sidecarURL(for: stagingURL)
        guard FileManager.default.fileExists(atPath: stagedSidecar.path) else { return }
        try? FileManager.default.moveItem(
            at: stagedSidecar, to: NativeMetadataWriter.sidecarURL(for: destinationURL))
    }

    /// Per docs/CLAUDE.md "File Safety": deletion always goes through the trash, even for a
    /// just-created destination copy that failed verification or metadata write, never
    /// `FileManager.removeItem`.
    private static func discardIncompleteCopy(at url: URL) {
        _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
