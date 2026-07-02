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

    /// Requests below this size are read in one exiftool invocation; larger batches are split so
    /// one invocation's runtime/output stays bounded for large import sessions.
    private static let readChunkSize = 50

    /// Reads full metadata for many files, batching them into as few exiftool invocations as
    /// possible. exiftool's cost per invocation is dominated by process/Perl-interpreter startup
    /// rather than the actual file read, so reading N files one at a time is roughly N times
    /// slower than reading them together.
    ///
    /// Each URL maps to either its metadata dictionary or the error that occurred reading it, so
    /// one unreadable or slow file in a chunk falls back to an individual `readMetadata(at:)`
    /// retry instead of failing every other file batched alongside it.
    func readMetadata(at urls: [URL]) async throws -> [URL: Result<[String: Any], Error>] {
        var results: [URL: Result<[String: Any], Error>] = [:]
        for chunk in stride(from: 0, to: urls.count, by: Self.readChunkSize).map({
            Array(urls[$0..<min($0 + Self.readChunkSize, urls.count)])
        }) {
            let bySourceFile = (try? await runChunk(chunk)) ?? [:]
            for url in chunk {
                if let match = bySourceFile[url.path] {
                    results[url] = .success(match)
                    continue
                }
                do {
                    results[url] = .success(try await readMetadata(at: url))
                } catch {
                    results[url] = .failure(error)
                }
            }
        }
        return results
    }

    /// Best-effort batched read for one chunk, keyed by exiftool's `SourceFile` tag. Any URL
    /// missing from the returned dictionary is retried individually by the caller, so this never
    /// throws.
    private func runChunk(_ urls: [URL]) async throws -> [String: [String: Any]] {
        let output = try await run(arguments: Self.readArguments + urls.map(\.path))
        guard let array = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
            return [:]
        }
        var bySourceFile: [String: [String: Any]] = [:]
        for entry in array {
            if let sourceFile = entry["SourceFile"] as? String {
                bySourceFile[sourceFile] = entry
            }
        }
        return bySourceFile
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
