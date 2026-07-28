import Foundation

/// Repackages a camera RAW file as a DNG, which is the only way to reach Apple's newest RAW decoder
/// for a camera model that decoder doesn't list — see `RawDevelopService` for the routing rule and
/// the measurements behind it.
///
/// A protocol rather than a concrete type because every implementation is inherently
/// platform-specific: `CGImageDestinationCopyTypeIdentifiers()` carries no DNG entry on macOS or
/// iOS, so ImageIO cannot do this, and the only converter on hand is a Mac-only application
/// (`AdobeDNGConverter`, in the app target for the same reason `ExifToolClient` lives there). Core
/// therefore knows the capability without depending on any way of providing it, and iPad simply
/// passes `nil`.
public protocol DNGConverting: Sendable {
    /// Writes a DNG built from `source` into `outputDirectory` and returns its URL. The caller owns
    /// `outputDirectory` and is responsible for cleaning it up.
    func convertToDNG(_ source: URL, outputDirectory: URL) async throws -> URL
}
