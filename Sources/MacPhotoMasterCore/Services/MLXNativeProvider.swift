import CoreImage
import Foundation
import MLX
import MLXLMCommon
import os

/// Native in-process `AIProvider` backend using mlx-swift-lm — no server, no Python, inference
/// runs directly via Metal against a Hugging Face model resolved through `MLXModelRegistry`.
/// Plugs into the same seam `OllamaProvider`/`OpenRouterProvider` use. See docs/MLX_PROVIDER.md
/// for the decision record (in-process vs. Python's `mlx_lm.server`) and known v1 limitations.
public struct MLXNativeProvider: AIProvider {
    public init() {}

    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "AISuggestion")

    /// Bounds MLX's GPU memory use once, on iOS only. iOS enforces a per-process jetsam memory limit
    /// (~6GB even with the `increased-memory-limit` entitlement); MLX's default (unbounded) free-buffer
    /// cache holds freed buffers as resident memory and pushes the high-watermark past that limit,
    /// getting the app killed mid-inference even for a small model like FastVLM-0.5B. Measured live
    /// working set for FastVLM at a 1024px image is ~2.7GB, so:
    ///   - `cacheLimit` 1GB: keep a generous free-buffer cache so buffers are reused across the
    ///     generation loop instead of being round-tripped to the OS every step (a tiny cache made
    ///     generation very slow); ~2.7GB live + up to 1GB cache still leaves headroom under ~6GB.
    ///   - `memoryLimit` 5GB (relaxed): a guardrail below the jetsam cap — MLX evicts cache to try to
    ///     stay under it, but `relaxed` lets a genuinely larger single allocation through rather than
    ///     failing. Doesn't constrain the ~2.7GB working set; only bounds cache growth.
    /// Not applied on macOS (128GB, no such cap, and an unbounded cache aids throughput there). Runs
    /// once via the `static let`'s lazy init.
    private static let gpuMemoryConfigured: Void = {
        #if os(iOS)
        MLX.GPU.set(cacheLimit: 1024 * 1024 * 1024)
        MLX.GPU.set(memoryLimit: 5 * 1024 * 1024 * 1024)
        #endif
    }()

    private static func configureGPUMemoryIfNeeded() { _ = gpuMemoryConfigured }

    /// Static/local allowlist check only — there's no cheap way to probe a not-yet-downloaded
    /// model's vision capability the way the HTTP-backed providers query a live `/api/tags` or
    /// `/api/models` endpoint, so "is it in our curated allowlist" stands in for that check.
    public func ensureVisionCapable(model: String) async throws {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw AISuggestionError.provider("No MLX model selected")
        }
        guard MLXModelRegistry.configuration(for: trimmedModel) != nil else {
            throw AISuggestionError.provider(
                "\"\(trimmedModel)\" is not a recognized MLX vision model")
        }
    }

    /// `think` is a no-op for this backend — mlx-swift-lm has no native "thinking effort" concept,
    /// and `AISuggestionService`'s retry path already reduces effort by sending a
    /// center-cropped/downscaled image rather than asking for a cheaper generation mode. There's
    /// also no manual timeout wrapper here: no `URLSession` boundary to hang off of, and local
    /// Metal inference on an already-loaded model doesn't fail the way flaky networking does — the
    /// `.timeout` retry path in `AISuggestionService` simply never fires for this provider.
    public func chat(
        model: String, systemPrompt: String, userPrompt: String, imagePayloads: [String], think: Bool
    ) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configuration = MLXModelRegistry.configuration(for: trimmedModel) else {
            throw AISuggestionError.provider(
                "\"\(trimmedModel)\" is not a recognized MLX vision model")
        }

        let images: [UserInput.Image] = try imagePayloads.map { payload in
            guard let image = Self.decodeImage(base64: payload) else {
                throw AISuggestionError.provider("Could not decode image for MLX request")
            }
            return .ciImage(image)
        }

        Self.configureGPUMemoryIfNeeded()
        let start = Date()
        do {
            let container = try await MLXModelManager.shared.container(
                for: trimmedModel, configuration: configuration)
            let session = ChatSession(container, instructions: systemPrompt)
            let response = try await session.respond(
                to: userPrompt, images: images, videos: [], audios: [])
            // mlx-swift-lm's token loop checks `Task.isCancelled` every iteration and ends the
            // stream (silently, with whatever partial text was generated) rather than throwing —
            // so a `Task.cancel()` on the caller's task (see `SourceBrowserViewModel.cancelAISuggestion`)
            // returns here promptly, but only this explicit check turns it into a clean
            // `CancellationError` instead of a misleading empty/partial response.
            try Task.checkCancellation()
            let elapsedSeconds = Date().timeIntervalSince(start)
            Self.logger.log(
                "MLX chat: model=\(trimmedModel, privacy: .public) elapsed=\(elapsedSeconds, privacy: .public)s"
            )

            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AISuggestionError.emptyResponse }
            return trimmed
        } catch let error as AISuggestionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AISuggestionError.provider("MLX inference failed: \(error.localizedDescription)")
        }
    }

    /// Extracted as a standalone function so it's unit-testable without loading MLX/Metal.
    public static func decodeImage(base64: String) -> CIImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return CIImage(data: data)
    }
}
