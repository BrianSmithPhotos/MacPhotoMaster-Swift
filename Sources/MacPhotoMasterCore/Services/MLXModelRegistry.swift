import Foundation
import MLXLMCommon

/// Curated allowlist of MLX vision models the native `mlx:` provider can load, keyed by the exact
/// Hugging Face repo id used after the `mlx:` prefix in `AIModelSelection` (e.g.
/// `"mlx:mlx-community/gemma-4-31b-it-8bit"`). This is the single source of truth
/// `MLXNativeProvider.ensureVisionCapable` validates against and `MLXModelManager` resolves
/// against — keep it in sync with `AIModelSelection.presets` by hand; nothing enforces that link
/// at compile time.
///
/// None of these repos have a `VLMRegistry.shared` curated static as of this writing (all are
/// community fine-tunes/conversions), so every entry is a `ModelConfiguration(id:)` literal built
/// directly against the real HF repo id, matching the `extraEOSTokens`/`defaultPrompt` convention
/// the library uses for other models sharing the same architecture. The dictionary key is just a
/// lookup label — it's the `ModelConfiguration`'s own `id` that determines what actually downloads,
/// so a key and its value's `id` must refer to the same HF repo.
public enum MLXModelRegistry {
    /// oMLX's Python inference server (not the Swift menu-bar app) downloads its own model
    /// weights into a flat, non-cache-format directory — `<repo>/config.json`,
    /// `<repo>/*.safetensors`, etc. — rather than the blob/snapshot layout `swift-huggingface`'s
    /// `HubClient` cache uses, so the two don't share downloads automatically even though both
    /// ultimately pull from `mlx-community` on Hugging Face. This is oMLX's default
    /// `model.model_dirs` from `~/.omlx/settings.json`. `configuration(for:)` checks here first so
    /// a model already fetched via oMLX's (more robust) downloader loads straight off disk instead
    /// of re-downloading multi-GB weights through ours.
    #if os(macOS)
    private static let omlxModelsDirectory =
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".omlx/models")
    #endif

    public static let configurations: [String: ModelConfiguration] = [
        "mlx-community/gemma-4-31b-it-8bit": ModelConfiguration(
            id: "mlx-community/gemma-4-31b-it-8bit",
            defaultPrompt: "Describe the image in English",
            extraEOSTokens: ["<turn|>"]
        ),
        "mlx-community/Qwen3.6-35B-A3B-4.4bit-msq": ModelConfiguration(
            id: "mlx-community/Qwen3.6-35B-A3B-4.4bit-msq",
            defaultPrompt: "Describe the image in English",
            extraEOSTokens: ["<|im_end|>"]
        ),
        "mlx-community/Qwen3.6-35B-A3B-8bit": ModelConfiguration(
            id: "mlx-community/Qwen3.6-35B-A3B-8bit",
            defaultPrompt: "Describe the image in English",
            extraEOSTokens: ["<|im_end|>"]
        ),
        // On-device-oriented FastVLM — see docs/MLX_PROVIDER.md for why this was added (candidate
        // for the iPad's much tighter memory budget vs. the ~20-40GB models above). Deliberately
        // *not* Apple's own `apple/FastVLM-0.5B-fp16` export: that repo's `preprocessor_config
        // .json` reports `processor_class: "LlavaProcessor"` (upstream LLaVA naming), which isn't
        // in mlx-swift-lm's `VLMProcessorTypeRegistry` — it only knows `"FastVLMProcessor"` for
        // this architecture, with no override entry for `llava_qwen2` the way there is for
        // `mistral3`/`gemma4_unified`. This repo is the community re-export mlx-swift-lm's own
        // `VLMRegistry.fastvlm` static points to, and correctly reports `processor_class:
        // "FastVLMProcessor"`.
        "mlx-community/FastVLM-0.5B-bf16": ModelConfiguration(
            id: "mlx-community/FastVLM-0.5B-bf16",
            defaultPrompt: "Describe the image in English",
            extraEOSTokens: ["<|im_end|>"]
        ),
    ]

    public static func configuration(for modelID: String) -> ModelConfiguration? {
        guard let configuration = configurations[modelID] else { return nil }

        #if os(macOS)
        guard case .id(let id, _) = configuration.id else { return configuration }

        let localDirectory = omlxModelsDirectory.appending(path: id)
        guard FileManager.default.fileExists(atPath: localDirectory.path) else {
            return configuration
        }
        return ModelConfiguration(
            directory: localDirectory,
            tokenizerSource: configuration.tokenizerSource,
            defaultPrompt: configuration.defaultPrompt,
            extraEOSTokens: configuration.extraEOSTokens,
            stopStrings: configuration.stopStrings,
            eosTokenIds: configuration.eosTokenIds,
            toolCallFormat: configuration.toolCallFormat
        )
        #else
        return configuration
        #endif
    }
}
