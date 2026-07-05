import MLXLMCommon
import MLXVLM

/// Curated allowlist of MLX vision models the native `mlx:` provider can load, keyed by the exact
/// Hugging Face repo id used after the `mlx:` prefix in `AIModelSelection` (e.g.
/// `"mlx:mlx-community/Qwen2.5-VL-3B-Instruct-4bit"`). This is the single source of truth
/// `MLXNativeProvider.ensureVisionCapable` validates against and `MLXModelManager` resolves
/// against — keep it in sync with `AIModelSelection.presets` by hand; nothing enforces that link
/// at compile time.
///
/// Where `VLMRegistry.shared` has a matching curated static configuration, values come from there
/// so this allowlist inherits the same EOS-token overrides mlx-swift-lm ships for each model. For
/// repos `VLMRegistry` doesn't carry (e.g. community fine-tunes), a `ModelConfiguration(id:)`
/// literal is constructed directly here, matching the `extraEOSTokens`/`defaultPrompt` convention
/// the library uses for other models sharing the same architecture. Either way, the dictionary key
/// is just a lookup label — it's the `ModelConfiguration`'s own `id` that determines what actually
/// downloads, so a key and its value's `id` must refer to the same HF repo.
enum MLXModelRegistry {
    static let configurations: [String: ModelConfiguration] = [
        "mlx-community/gemma-3-12b-it-qat-4bit": VLMRegistry.gemma3_12B_qat_4bit,
        "mlx-community/gemma-3-27b-it-qat-4bit": VLMRegistry.gemma3_27B_qat_4bit,
        "mlx-community/gemma-4-26b-a4b-it-4bit": VLMRegistry.gemma4_26BA4B_it_4bit,
        "mlx-community/gemma-4-31b-it-4bit": VLMRegistry.gemma4_31B_it_4bit,
        "mlx-community/Qwen3.6-35B-A3B-4.4bit-msq": ModelConfiguration(
            id: "mlx-community/Qwen3.6-35B-A3B-4.4bit-msq",
            defaultPrompt: "Describe the image in English",
            extraEOSTokens: ["<|im_end|>"]
        ),
        "mlx-community/Ornith-1.0-35B-bf16": ModelConfiguration(
            id: "mlx-community/Ornith-1.0-35B-bf16",
            defaultPrompt: "Describe the image in English",
            extraEOSTokens: ["<|im_end|>"]
        ),
        "mlx-community/Qwen3-VL-8B-Instruct-4bit": ModelConfiguration(
            id: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
            defaultPrompt: "Describe the image in English",
            extraEOSTokens: ["<|im_end|>"]
        ),
        "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit": ModelConfiguration(
            id: "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit"
        ),
    ]

    static func configuration(for modelID: String) -> ModelConfiguration? {
        configurations[modelID]
    }
}
