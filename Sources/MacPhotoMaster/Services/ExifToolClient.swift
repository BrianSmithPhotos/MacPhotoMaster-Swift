import Foundation

enum ExifToolError: Error {
    case processFailed(status: Int32, stderr: String)
    case invalidOutput
}

/// Thin wrapper around the `exiftool` binary. All EXIF/IPTC/XMP read/write goes through here —
/// no hand-rolled metadata parsing. See docs/ARCHITECTURE.md "exiftool integration".
struct ExifToolClient {
    /// `-j -G1 -a -s` matches the reference app's read command: JSON output, grouped tag names,
    /// duplicate tags allowed, short tag names. See docs/SPEC.md §2.
    private static let readArguments = ["-j", "-G1", "-a", "-s"]

    /// Reads full metadata for one file as exiftool's raw JSON object (one entry per requested tag
    /// group). Field-mapping to `PhotoAsset` happens one layer up.
    func readMetadata(at url: URL) async throws -> [String: Any] {
        let output = try await run(arguments: Self.readArguments + [url.path])
        guard let array = try JSONSerialization.jsonObject(with: output) as? [[String: Any]],
              let first = array.first
        else {
            throw ExifToolError.invalidOutput
        }
        return first
    }

    private func run(arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            // Resolve via PATH rather than hardcoding a Homebrew prefix (Apple Silicon vs Intel differ).
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["exiftool"] + arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { finished in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                guard finished.terminationStatus == 0 else {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ExifToolError.processFailed(status: finished.terminationStatus, stderr: stderr))
                    return
                }
                continuation.resume(returning: stdoutData)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
