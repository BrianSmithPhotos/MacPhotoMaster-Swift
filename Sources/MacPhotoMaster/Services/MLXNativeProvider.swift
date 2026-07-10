import CoreImage
import Foundation
import MLXLMCommon
import os

/// Native in-process `AIProvider` backend using mlx-swift-lm — no server, no Python, inference
/// runs directly via Metal against a Hugging Face model resolved through `MLXModelRegistry`.
/// Plugs into the same seam `OllamaProvider`/`OpenRouterProvider` use. See docs/MLX_PROVIDER.md
/// for the decision record (in-process vs. Python's `mlx_lm.server`) and known v1 limitations.
struct MLXNativeProvider: AIProvider {
    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "AISuggestion")

    /// Static/local allowlist check only — there's no cheap way to probe a not-yet-downloaded
    /// model's vision capability the way the HTTP-backed providers query a live `/api/tags` or
    /// `/api/models` endpoint, so "is it in our curated allowlist" stands in for that check.
    func ensureVisionCapable(model: String) async throws {
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
    func chat(
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
    static func decodeImage(base64: String) -> CIImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return CIImage(data: data)
    }
}
