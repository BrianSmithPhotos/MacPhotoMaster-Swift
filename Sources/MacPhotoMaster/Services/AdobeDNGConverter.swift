import AppKit
import Foundation
import MacPhotoMasterCore

enum AdobeDNGConverterError: Error, Equatable {
    case processFailed(status: Int32, stderr: String)
    case outputMissing(URL)
    case timedOut
}

/// Repackages a camera RAW as a DNG by shelling out to Adobe DNG Converter, so Apple's decoder 9
/// can be reached for a camera model it doesn't list — see `RawDevelopService` for the routing.
///
/// Lives in the Mac app target rather than Core for the same reason `ExifToolClient` does: it
/// depends on an external Mac-only program. iPad has no equivalent, which is why `DNGConverting` is
/// a protocol and `RawDevelopService` accepts `nil` for it.
struct AdobeDNGConverter: DNGConverting {
    /// Roughly 30x the ~1.4s a 20MP ORF takes on this machine. The generous margin is deliberate:
    /// the concern isn't a slow conversion but a malformed invocation, which makes this app open
    /// its window and wait for a person instead of exiting — observed while working out the CLI
    /// flags. A hung GUI would otherwise block the develop task forever.
    private static let timeoutSeconds: Double = 45

    private let executableURL: URL

    /// Fails when Adobe DNG Converter isn't installed, which is not an error condition — the caller
    /// passes `nil` to `RawDevelopService` and RAW files simply develop at the newest decoder they
    /// reach on their own.
    ///
    /// Located by bundle identifier rather than a hardcoded `/Applications` path, mirroring the
    /// "don't rely on one fixed location" reasoning in docs/ARCHITECTURE.md for the exiftool binary,
    /// and the executable is read from `CFBundleExecutable` rather than assumed to match the app
    /// name.
    init?() {
        guard
            let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.adobe.DNGConverter"),
            let executableURL = Bundle(url: appURL)?.executableURL
        else {
            return nil
        }
        self.executableURL = executableURL
    }

    /// `-c` lossless-compresses, `-p0` embeds no JPEG preview (nothing here ever looks at one — the
    /// DNG exists only to be handed straight back to `CIRAWFilter`), and `-d` puts the result in the
    /// caller's directory instead of beside the original, which matters because the original is
    /// often on a full SD card.
    func convertToDNG(_ source: URL, outputDirectory: URL) async throws -> URL {
        let destination = outputDirectory
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("dng")
        let executableURL = self.executableURL

        try await Task.detached(priority: .userInitiated) {
            try Self.run(
                executableURL: executableURL,
                arguments: ["-c", "-p0", "-d", outputDirectory.path, source.path])
        }.value

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw AdobeDNGConverterError.outputMissing(destination)
        }
        return destination
    }

    /// stdout is discarded and stderr drained to EOF *before* waiting on the process — reading first
    /// is what keeps a child that outputs more than the pipe buffer from blocking on its own write
    /// while this side blocks on exit. Same hazard `ExifToolClient.run` documents at length; it
    /// needs the more elaborate treatment there because it must capture stdout too.
    ///
    /// A non-empty stderr does not mean failure: a successful conversion still prints a GPU
    /// configuration warning. Only the exit status decides.
    private static func run(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let timeout = TimeoutFlag()
        try process.run()

        let workItem = DispatchWorkItem {
            timeout.mark()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: workItem)

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        workItem.cancel()

        if timeout.didFire {
            throw AdobeDNGConverterError.timedOut
        }
        guard process.terminationStatus == 0 else {
            throw AdobeDNGConverterError.processFailed(
                status: process.terminationStatus,
                stderr: String(data: stderrData, encoding: .utf8) ?? "")
        }
    }

    /// The timeout's work item and this thread touch the flag concurrently, so it needs a lock
    /// rather than a captured `var`.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func mark() {
            lock.lock()
            fired = true
            lock.unlock()
        }

        var didFire: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }
}
