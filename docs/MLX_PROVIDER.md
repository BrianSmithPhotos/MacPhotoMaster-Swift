# Native MLX AI provider

`MLXNativeProvider` is a third `AIProvider` backend (alongside `OllamaProvider` and
`OpenRouterProvider`) that runs vision-model inference **natively in-process** via Apple's
[`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) — no server, no daemon, no Python.
It was added as a deliberate exercise in the native MLX stack, not because Ollama's own MLX backend
(see CLAUDE.md "Hardware & model notes") was found lacking.

## Decision record: in-process, not `mlx_lm.server`

`mlx-swift-lm` is a Swift library, not a server. The Python `mlx-lm` package's `mlx_lm.server`
(an OpenAI-compatible local HTTP server) is a separate, Python-only project and was deliberately
**not** used — that would just be a third HTTP-based provider like Ollama/OpenRouter, not an
exercise in the native Swift stack. `MLXNativeProvider` calls `mlx-swift-lm`'s `ChatSession` API
directly; there is no HTTP round-trip anywhere in this backend.

## Package pins

`Package.swift` bumped `swift-tools-version` to `6.1` — required for `mlx-swift-lm`'s macro target
— but pins `swiftLanguageModes: [.v5]` so the app's own code keeps Swift 5 concurrency semantics
rather than picking up strict-concurrency checking as a side effect of the manifest-format bump.

Resolved versions (`Package.resolved`):

| Package | Version |
|---|---|
| `mlx-swift-lm` | 3.31.4 |
| `swift-huggingface` | 0.9.0 |
| `swift-transformers` | 1.3.3 |

Model loading goes through the `#huggingFaceLoadModelContainer(configuration:)` macro
(`MLXHuggingFace`), which downloads (if needed) and loads a model from Hugging Face using the
default `HubClient`/tokenizer integration — standard `~/.cache/huggingface` layout, no auth needed
for the public `mlx-community/*` repos this app uses.

## Model allowlist

`MLXModelRegistry.configurations` is the single source of truth both `MLXNativeProvider
.ensureVisionCapable` and `MLXModelManager` resolve against, keyed by the exact Hugging Face repo id
used after the `mlx:` prefix in `AIModelSelection`. Keep it in sync with
`AIModelSelection.presets`'s `mlx:` entries by hand — nothing enforces that link at compile time.

| HF repo id | Size | Notes |
|---|---|---|
| `mlx-community/Qwen2.5-VL-3B-Instruct-4bit` | ~2 GB | Smallest/fastest — good first-download choice |
| `mlx-community/Qwen3-VL-4B-Instruct-8bit` | ~4-5 GB | Recommended default `mlx:` preset |
| `mlx-community/gemma-3-12b-it-qat-4bit` | ~7 GB | "Quality" option, slower |

Larger `VLMRegistry` entries (27B/35B) are reachable by typing the id directly in the free-text
model field but are intentionally left out of the curated preset list — large download, slower
iteration for what's meant to stay a learning exercise.

## Known v1 limitations

- **No think-mode differentiation.** `think` is a no-op for this backend — mlx-swift-lm has no
  native "thinking effort" concept, and `AISuggestionService`'s retry path already reduces effort by
  sending a center-cropped/downscaled image, not by requesting a cheaper generation mode.
- **No request-level timeout.** There's no `URLSession` boundary to hang a timeout off of, and local
  Metal inference on an already-loaded model doesn't fail the way flaky networking does. The
  `.timeout` retry path in `AISuggestionService` simply never fires for this provider.
- **No download-progress UI.** First use of a model not yet cached locally is a slow, silent
  multi-GB download; the existing "Generating AI suggestions…" status message is the only feedback.
- **Single-model-resident cache.** `MLXModelManager` holds at most one `ModelContainer` at a time —
  switching to a different `mlx:` model evicts the previous one rather than keeping several
  multi-GB VLMs resident simultaneously.
- **No wired-memory ticket.** `ChatSession`'s generation path doesn't expose a `wiredMemoryTicket`
  parameter (that's only on the lower-level `ModelContainer.generate(...)` API), so this provider
  doesn't apply a `WiredMemoryPolicy` — there's nothing to wire it into without dropping to that
  lower-level API, which wasn't judged worth the added complexity for v1.
- **System prompt threading.** `ChatSession(container, instructions: systemPrompt)` threads the
  system prompt automatically as a leading `.system(...)` message — no manual concatenation into the
  user turn was needed, unlike the fallback the original implementation plan considered.

## Manual smoke test

1. `swift build`, then `swift run`.
2. In the AI Model field, pick or type an `mlx:` preset (e.g.
   `mlx:mlx-community/Qwen2.5-VL-3B-Instruct-4bit` — smallest, fastest first download).
3. Select a photo, click "Suggest Description + Keywords".
4. First run against a new model downloads it to `~/.cache/huggingface` — this can take a while with
   no progress indicator (see limitations above); subsequent runs against the same model are fast.
5. Confirm the description/keywords populate and auto-save, the same as the Ollama/OpenRouter paths.
