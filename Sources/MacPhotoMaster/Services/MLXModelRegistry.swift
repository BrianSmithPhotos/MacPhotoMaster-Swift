import MLXLMCommon
import MLXVLM

/// Curated allowlist of MLX vision models the native `mlx:` provider can load, keyed by the exact
/// Hugging Face repo id used after the `mlx:` prefix in `AIModelSelection` (e.g.
/// `"mlx:mlx-community/Qwen2.5-VL-3B-Instruct-4bit"`). This is the single source of truth
/// `MLXNativeProvider.ensureVisionCapable` validates against and `MLXModelManager` resolves
/// against — keep it in sync with `AIModelSelection.presets` by hand; nothing enforces that link
/// at compile time.
///
/// Values come from `VLMRegistry.shared`'s curated static configurations rather than constructing
/// `ModelConfiguration(id:)` directly, so this allowlist inherits the same EOS-token overrides
/// mlx-swift-lm ships for each model.
enum MLXModelRegistry {
    static let configurations: [String: ModelConfiguration] = [
        "mlx-community/Qwen2.5-VL-3B-Instruct-4bit": VLMRegistry.qwen2_5VL3BInstruct4Bit,
        "mlx-community/Qwen3-VL-4B-Instruct-8bit": VLMRegistry.qwen3VL4BInstruct8Bit,
        "mlx-community/gemma-3-12b-it-qat-4bit": VLMRegistry.gemma3_12B_qat_4bit,
    ]

    static func configuration(for modelID: String) -> ModelConfiguration? {
        configurations[modelID]
    }
}
