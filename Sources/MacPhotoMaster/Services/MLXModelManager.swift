import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers
import os

/// Holds at most one resident `ModelContainer` for the native MLX provider — switching models
/// drops the old container so two multi-GB VLMs are never resident at once. `ModelContainer` is
/// `Sendable` and safe to hold as a long-lived singleton (docs on the type itself guarantee
/// thread-safe access via `.perform { }`).
///
/// First use of a model not yet in `~/.cache/huggingface` triggers a slow, silent multi-GB
/// download — there's no download-progress UI in v1 (see docs/MLX_PROVIDER.md); the caller's
/// existing "Generating AI suggestions…" status message is the only feedback for now.
actor MLXModelManager {
    static let shared = MLXModelManager()

    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "AISuggestion")

    private var current: (modelID: String, container: ModelContainer)?

    private init() {}

    /// Returns the resident container for `modelID`, loading (and downloading, if needed) it via
    /// Hugging Face if it isn't already resident. `configuration` must be the allowlisted entry
    /// from `MLXModelRegistry` for `modelID`.
    func container(for modelID: String, configuration: ModelConfiguration) async throws
        -> ModelContainer
    {
        if let current, current.modelID == modelID {
            return current.container
        }

        let start = Date()
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        let elapsedSeconds = Date().timeIntervalSince(start)
        Self.logger.log(
            "MLX model load: id=\(modelID, privacy: .public) elapsed=\(elapsedSeconds, privacy: .public)s"
        )

        current = (modelID, container)
        return container
    }
}
