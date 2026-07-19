import CryptoKit
import Foundation

/// Shared chunked SHA-256 helper — used by `ProcessMoveService` to verify a copy and by the
/// Timeline import path to detect a changed export file.
public enum FileHashing {
    private static let chunkSize = 1024 * 1024

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
