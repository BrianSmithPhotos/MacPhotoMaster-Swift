import Foundation

/// Which `AIProvider` conformance a model string routes to.
public enum AIProviderID: String {
    case ollama
    case openRouter = "openrouter"
    case mlx
}

/// Parses the `"<provider>:<model>"` convention `SourceBrowserViewModel.aiModelText` uses (e.g.
/// `"ollama:qwen3.6:35b"`, `"openrouter:google/gemini-2.5-flash"`). Splits on the *first* colon
/// only — Ollama's own model-tag format embeds a colon (`"qwen2.5vl:72b"`), while OpenRouter slugs
/// use `/` and never contain one, so this is unambiguous.
public struct AIModelSelection {
    public let providerID: AIProviderID
    public let modelName: String

    public static func parse(_ text: String) -> AIModelSelection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colonIndex = trimmed.firstIndex(of: ":") else { return nil }
        guard let providerID = AIProviderID(rawValue: String(trimmed[..<colonIndex])) else { return nil }
        let modelName = String(trimmed[trimmed.index(after: colonIndex)...])
        guard !modelName.isEmpty else { return nil }
        return AIModelSelection(providerID: providerID, modelName: modelName)
    }

    /// Default preset list for the AI Model dropdown, in the user-specified order — the field stays
    /// freely editable for any model not in this list.
    public static let presets: [String] = [
        "mlx:mlx-community/gemma-4-31b-it-8bit",
        "ollama:qwen3.6:35b",
        "openrouter:google/gemini-2.5-flash",
        "openrouter:google/gemini-3.1-flash-lite-image",
        "openrouter:openai/gpt-5.1",
        "openrouter:google/gemini-3.5-flash",
        "openrouter:anthropic/claude-opus-4.8",
        "openrouter:openai/gpt-5.5",
        "openrouter:openai/gpt-5.6-luna",
        "openrouter:openai/gpt-4o-mini",
        "ollama:qwen2.5vl:72b",
        "openrouter:qwen/qwen2.5-vl-72b-instruct",
        "openrouter:anthropic/claude-sonnet-5",
        "openrouter:mistralai/mistral-medium-3-5",
        "ollama:gemma4:12b",
        "ollama:moondream:latest",
        "mlx:mlx-community/Qwen3.6-35B-A3B-4.4bit-msq",
        "mlx:mlx-community/Qwen3.6-35B-A3B-8bit",
        "mlx:mlx-community/gemma-3-4b-it-4bit",
        "mlx:mlx-community/FastVLM-0.5B-bf16",
    ]
}
