import Foundation

enum ExifToolError: Error {
    case processFailed(status: Int32, stderr: String)
    case invalidOutput
    case timedOut
}

/// A GPS fix to write. Latitude/longitude are required together (an EXIF fix without one or the
/// other is meaningless), so pairing them in one type rules out that inconsistent state at compile
/// time rather than needing a runtime check like the Python reference app does. See docs/SPEC.md §3
/// for the Ref-tag-from-sign convention.
struct GPSCoordinate: Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
}

enum MetadataWriteError: Error, Equatable {
    case invalidLatitude(Double)
    case invalidLongitude(Double)
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

    /// Writes title/description/keywords/GPS to a single file. `title` is per-file-unique (it's
    /// usually rename-derived), so it's only exposed here, never in the batched overload below —
    /// see docs/SPEC.md §3.
    ///
    /// Relies on exiftool's own automatic `<path>_original` backup rather than `-overwrite_original`:
    /// on success the backup is deleted; on failure the backup is restored over the (possibly
    /// half-written) file so the write is all-or-nothing from the caller's perspective.
    func write(title: String?, description: String, keywords: [String], gps: GPSCoordinate?, to url: URL) async throws {
        try Self.validate(gps: gps)
        let arguments = Self.writeArguments(title: title, description: description, keywords: keywords, gps: gps) + [url.path]
        do {
            _ = try await run(arguments: arguments, timeoutSeconds: Self.singleFileTimeout)
            cleanupBackup(for: url)
        } catch {
            restoreBackupIfPresent(for: url)
            throw error
        }
    }

    /// Writes the same description/keywords/GPS to every file in `urls` in one exiftool invocation
    /// — the batching optimization from docs/ARCHITECTURE.md "exiftool integration". Grouping files
    /// by identical target values is the caller's job (e.g. a capture-set save); this method just
    /// writes whatever list it's given.
    ///
    /// exiftool's exit code reflects the whole invocation, not which of several files in it
    /// succeeded (confirmed empirically: a batch with one bad path among good ones still writes the
    /// good ones but exits non-zero). So on any failure this restores every file's backup — even
    /// ones exiftool did manage to write — rather than guessing which succeeded, then retries each
    /// file individually so a single bad file doesn't cost the whole group its write.
    func write(description: String, keywords: [String], gps: GPSCoordinate?, to urls: [URL]) async throws -> [URL: Result<Void, Error>] {
        try Self.validate(gps: gps)
        guard !urls.isEmpty else { return [:] }

        let arguments = Self.writeArguments(title: nil, description: description, keywords: keywords, gps: gps) + urls.map(\.path)
        do {
            _ = try await run(arguments: arguments, timeoutSeconds: Self.batchTimeoutPerFile * Double(urls.count))
            for url in urls { cleanupBackup(for: url) }
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, .success(())) })
        } catch {
            for url in urls { restoreBackupIfPresent(for: url) }
            var results: [URL: Result<Void, Error>] = [:]
            for url in urls {
                do {
                    try await write(title: nil, description: description, keywords: keywords, gps: gps, to: url)
                    results[url] = .success(())
                } catch {
                    results[url] = .failure(error)
                }
            }
            return results
        }
    }

    /// Matches the reference app's per-file/per-file-in-batch timeouts (12s per file) — see
    /// docs/ARCHITECTURE.md "exiftool integration".
    private static let singleFileTimeout: Double = 12
    private static let batchTimeoutPerFile: Double = 12

    private static func validate(gps: GPSCoordinate?) throws {
        guard let gps else { return }
        guard (-90...90).contains(gps.latitude) else { throw MetadataWriteError.invalidLatitude(gps.latitude) }
        guard (-180...180).contains(gps.longitude) else { throw MetadataWriteError.invalidLongitude(gps.longitude) }
    }

    /// Builds the `-TAG=value` argv per docs/SPEC.md §3's field->tag table. Keywords are cleared
    /// (blank `-IPTC:Keywords=`/`-XMP-dc:Subject=`) before being rewritten one `-tag=value` pair at
    /// a time — the idempotent way to "replace the keyword list" with exiftool, since its `+=`
    /// append operator would duplicate keywords on every re-save.
    private static func writeArguments(title: String?, description: String, keywords: [String], gps: GPSCoordinate?) -> [String] {
        var arguments: [String] = []
        if let title {
            arguments.append("-IPTC:ObjectName=\(title)")
            arguments.append("-XMP-dc:Title=\(title)")
        }
        arguments.append("-IPTC:Caption-Abstract=\(description)")
        arguments.append("-XMP-dc:Description=\(description)")

        arguments.append("-IPTC:Keywords=")
        arguments.append("-XMP-dc:Subject=")
        for keyword in normalizedKeywords(keywords) {
            arguments.append("-IPTC:Keywords=\(keyword)")
            arguments.append("-XMP-dc:Subject=\(keyword)")
        }

        if let gps {
            arguments.append("-GPSLatitude=\(gps.latitude)")
            arguments.append("-GPSLatitudeRef=\(gps.latitude >= 0 ? "N" : "S")")
            arguments.append("-GPSLongitude=\(gps.longitude)")
            arguments.append("-GPSLongitudeRef=\(gps.longitude >= 0 ? "E" : "W")")
            if let altitude = gps.altitude {
                arguments.append("-GPSAltitude=\(altitude)")
                // exiftool's default (non-numeric) write mode only recognizes GPSAltitudeRef's
                // descriptive PrintConv strings as input — writing the raw byte value ("0"/"1")
                // directly is silently coerced to 0 regardless of what's given (confirmed
                // empirically against exiftool 13.55; the Python reference app writes the raw
                // byte and appears to have the same latent bug).
                arguments.append("-GPSAltitudeRef=\(altitude >= 0 ? "Above Sea Level" : "Below Sea Level")")
            }
        }
        return arguments
    }

    /// Trims, drops blanks, and dedupes case-insensitively (keeping the first-seen casing) so
    /// re-saving the same keyword list twice — or a list with only casing differences — doesn't
    /// grow the file's keyword tag on every save.
    private static func normalizedKeywords(_ keywords: [String]) -> [String] {
        var seenLowercased = Set<String>()
        var result: [String] = []
        for keyword in keywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seenLowercased.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "_original")
    }

    private func cleanupBackup(for url: URL) {
        try? FileManager.default.removeItem(at: backupURL(for: url))
    }

    private func restoreBackupIfPresent(for url: URL) {
        let backup = backupURL(for: url)
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: backup, to: url)
    }

    /// Homebrew install locations to fall back to when `PATH` doesn't resolve exiftool. macOS
    /// launches .app bundles (Dock/Finder) with a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`)
    /// that excludes these, so a `PATH`-only lookup that works when run from Xcode/a terminal
    /// fails silently once bundled.
    private static let homebrewExiftoolCandidates = [
        "/opt/homebrew/bin/exiftool",  // Apple Silicon
        "/usr/local/bin/exiftool",  // Intel
    ]

    /// Resolved once per process: checks `PATH` first (covers `swift run`/Xcode where the
    /// launching shell's environment is inherited), then the known Homebrew locations.
    private static let exiftoolPath: String = {
        if let pathVariable = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathVariable.split(separator: ":") {
                let candidate = "\(directory)/exiftool"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        for candidate in homebrewExiftoolCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "exiftool"
    }()

    /// Coordinates `run(arguments:timeoutSeconds:)`'s three independent async completion sources
    /// (stdout drained to EOF, stderr drained to EOF, process termination) and resumes the
    /// continuation exactly once all three have reported in — see that method's doc comment for
    /// why stdout/stderr must be drained on their own background reads rather than only inside
    /// `terminationHandler`.
    private final class RunCompletionState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData: Data?
        private var stderrData: Data?
        private var termination: (status: Int32, didTimeOut: Bool)?
        private var resumed = false
        private let continuation: CheckedContinuation<Data, Error>

        init(continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
        }

        func receiveStdout(_ data: Data) {
            lock.lock()
            stdoutData = data
            lock.unlock()
            tryResume()
        }

        func receiveStderr(_ data: Data) {
            lock.lock()
            stderrData = data
            lock.unlock()
            tryResume()
        }

        func receiveTermination(status: Int32, didTimeOut: Bool) {
            lock.lock()
            termination = (status, didTimeOut)
            lock.unlock()
            tryResume()
        }

        private func tryResume() {
            lock.lock()
            guard !resumed, let stdoutData, let stderrData, let termination else {
                lock.unlock()
                return
            }
            resumed = true
            lock.unlock()

            if termination.didTimeOut {
                continuation.resume(throwing: ExifToolError.timedOut)
                return
            }
            guard termination.status == 0 else {
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(
                    throwing: ExifToolError.processFailed(status: termination.status, stderr: stderr))
                return
            }
            continuation.resume(returning: stdoutData)
        }
    }

    /// `Process.terminationHandler` and the timeout's `DispatchWorkItem` both run on background
    /// queues concurrently with each other, so the flag they race on needs its own lock rather than
    /// a plain captured `var` (which the Swift 6 concurrency checker correctly flags as unsafe).
    private final class TimeoutState: @unchecked Sendable {
        private let lock = NSLock()
        private var didTimeOut = false
        var workItem: DispatchWorkItem?

        /// Called from the timeout's `DispatchWorkItem` — `Process.terminate()` on an
        /// already-exited process is a harmless no-op, so no race check is needed here.
        func markTimedOut() {
            lock.lock()
            defer { lock.unlock() }
            didTimeOut = true
        }

        /// Called from `terminationHandler`. Cancels the timeout (it's moot once the process has
        /// exited on its own) and reports whether the timeout had already fired.
        func cancelAndCheckTimedOut() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            workItem?.cancel()
            return didTimeOut
        }
    }

    /// Runs `exiftool` and returns its stdout, or throws on a nonzero exit/timeout.
    ///
    /// stdout/stderr are drained on their own background reads started right after `process.run()`,
    /// not from inside `terminationHandler` — `readDataToEndOfFile()` blocks on each `read()` until
    /// data is available or EOF, so this drains continuously as exiftool writes rather than waiting
    /// for the process to exit first. That distinction matters: a `-j -G1 -a -s` read across even a
    /// couple of files can push stdout past the pipe's ~64KB kernel buffer (Olympus/OM System
    /// MakerNotes are especially verbose), and if that's left undrained until termination, exiftool
    /// blocks on its own `write()` into the full pipe and can never reach exit — deadlocking this
    /// call forever. `RunCompletionState` resumes the continuation once stdout, stderr, and
    /// termination have all reported in, however they interleave.
    private func run(arguments: [String], timeoutSeconds: Double? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.exiftoolPath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let timeoutState = TimeoutState()
            let completion = RunCompletionState(continuation: continuation)

            DispatchQueue.global(qos: .utility).async {
                completion.receiveStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
            DispatchQueue.global(qos: .utility).async {
                completion.receiveStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }

            process.terminationHandler = { finished in
                let didTimeOut = timeoutState.cancelAndCheckTimedOut()
                completion.receiveTermination(status: finished.terminationStatus, didTimeOut: didTimeOut)
            }

            do {
                try process.run()
                if let timeoutSeconds {
                    let workItem = DispatchWorkItem {
                        timeoutState.markTimedOut()
                        process.terminate()
                    }
                    timeoutState.workItem = workItem
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: workItem)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
