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

### Sharing downloads with oMLX

[oMLX](https://github.com/BrianSmithPhotos/omlx)'s Python inference server has its own, more
robust model downloader and stores weights flat at `~/.omlx/models/<repo>/` — a different, non
cache-format layout from this app's `~/.cache/huggingface/hub`, so the two don't share downloads
automatically even for the same `mlx-community` repo. `MLXModelRegistry.configuration(for:)` checks
`~/.omlx/models/<repo>` first and, if the repo is already there, loads it directly via
`ModelConfiguration(directory:)` instead of re-downloading multi-GB weights through this app's own
`HubClient`. **Recommended workflow**: pull a new model down via oMLX's model manager first, then
add the same repo id to `MLXModelRegistry`/`AIModelSelection.presets` here — the fallback picks it
up with no further wiring.

## Model allowlist

`MLXModelRegistry.configurations` is the single source of truth both `MLXNativeProvider
.ensureVisionCapable` and `MLXModelManager` resolve against, keyed by the exact Hugging Face repo id
used after the `mlx:` prefix in `AIModelSelection`. Keep it in sync with
`AIModelSelection.presets`'s `mlx:` entries by hand — nothing enforces that link at compile time.
Where `VLMRegistry.shared` has a matching curated static, the entry reuses it; where it doesn't
(community fine-tunes not shipped by mlx-swift-lm), the entry is a `ModelConfiguration(id:)` literal
built directly against the real HF repo id — either way the dictionary key and the value's `id` must
name the same repo, since it's the `id` that's actually downloaded, not the key (though at runtime
`configuration(for:)` may swap that `id` for a local `.directory` if oMLX already has it — see
above).

| HF repo id | Size | Notes |
|---|---|---|
| `mlx-community/gemma-3-12b-it-qat-4bit` | ~7 GB | Manually verified: loads and returns a description, though accuracy was mediocre |
| `mlx-community/gemma-3-27b-it-qat-4bit` | ~16 GB | Untested as of this writing — `VLMRegistry` static, no registry work needed |
| `mlx-community/gemma-4-26b-a4b-it-4bit` | ~15 GB | Untested as of this writing |
| `mlx-community/gemma-4-31b-it-4bit` | ~18 GB | `VLMRegistry` static, dense `gemma4` architecture (registered in this pinned mlx-swift-lm version). Untested as of this writing — pick this over the `-bf16` release of the same model (~62.5 GB, unquantized) unless accuracy testing shows the 4-bit quant is the problem |
| `mlx-community/gemma-4-31b-it-8bit` | ~34 GB | `ModelConfiguration(id:)` literal, instruction-tuned 8-bit conversion of `google/gemma-4-31b-it`. Originally registered as `mlx-community/gemma-4-31b-8bit` (the *base*, non-instruction-tuned conversion) — swapped after that produced a "tokenizer does not have a chat template" error: `mlx-community/gemma-4-31b-8bit`/`google/gemma-4-31b` are pretrained-only repos and never shipped one, and neither does the already-registered `-it-4bit` entry above, but `Gemma4.swift`'s `prepare(input:)` has no fallback template and throws when it's missing. **When adding any gemma4 (or other) community conversion, confirm the repo is an `-it-`/instruction-tuned release before registering it** — a base-model conversion will hit this every time, not just for gemma4 |
| `mlx-community/Qwen3.6-35B-A3B-4.4bit-msq` | ~21 GB | `ModelConfiguration(id:)` literal — not a `VLMRegistry` static. Manually verified: loads and returns a usable (imperfect) description, noticeably slower than gemma-3-12b |
| `mlx-community/Qwen3.6-35B-A3B-8bit` | ~38 GB | `ModelConfiguration(id:)` literal (8-bit conversion of the same `Qwen/Qwen3.6-35B-A3B` base as the 4.4bit-msq entry above). Untested as of this writing |

**Removed from the preset list after manual testing**: `mlx-community/Qwen2.5-VL-3B-Instruct-4bit`
and `mlx-community/Qwen3-VL-4B-Instruct-8bit` both returned an empty response (never a crash) against
a real photo — the smaller Qwen2/2.5/3-VL models in this mlx-swift-lm version appear to hit this
regardless of prompt content. Root cause not yet investigated (would need to trace `Qwen25VL.swift`/
`Qwen3VL.swift`'s processor/generation path against a live repro). Both ids are still reachable by
typing them directly into the free-text model field if this is worth revisiting later.

**Researched and deliberately excluded — would fail to load, not just be slow**: any
`Qwen3-VL-30B-A3B-*`/`Qwen3-VL-235B-A22B-*` variant and `mlx-community/GLM-4.5V-3bit`. Checked each
repo's `config.json` directly: these report `model_type: "qwen3_vl_moe"` and `"glm4v_moe"`
respectively, and `VLMTypeRegistry.shared` in this pinned mlx-swift-lm version (3.31.4) only
registers dense `"qwen3_vl"` and a narrower `"glm_ocr"` type — neither MoE variant has a matching
entry, so `#huggingFaceLoadModelContainer` would throw an unrecognized-architecture error before any
inference. Worth revisiting only if a future mlx-swift-lm bump adds `"qwen3_vl_moe"`/`"glm4v_moe"` to
`VLMTypeRegistry`.

## Known v1 limitations

- **No think-mode differentiation.** `think` is a no-op for this backend — mlx-swift-lm has no
  native "thinking effort" concept, and `AISuggestionService`'s retry path already reduces effort by
  sending a center-cropped/downscaled image, not by requesting a cheaper generation mode.
- **No request-level timeout — manual cancel instead.** There's no `URLSession` boundary to hang a
  timeout off of, and local Metal inference on an already-loaded model doesn't fail the way flaky
  networking does, so the `.timeout` retry path in `AISuggestionService` never fires for this
  provider. A stuck/runaway generation (observed once with `Qwen3.6-35B-A3B-8bit` — it never
  returned and eventually triggered a system out-of-memory warning) has no automatic recovery, so
  `SourceBrowserViewModel.cancelAISuggestion()` gives the user a manual "Stop" button next to
  "Suggest" instead: it cancels the `Task` `startAISuggestion()` created, which
  `MLXNativeProvider.chat` observes cooperatively via `Task.checkCancellation()` — the same
  per-token `Task.isCancelled` check mlx-swift-lm's own generation loop (`Evaluate.swift`) already
  uses internally, so cancellation lands within about one token's worth of latency rather than
  waiting for the whole response.
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
   `mlx:mlx-community/gemma-3-12b-it-qat-4bit` — smallest currently-preset, fastest first download).
3. Select a photo, click "Suggest Description + Keywords".
4. First run against a new model downloads it to `~/.cache/huggingface` — this can take a while with
   no progress indicator (see limitations above); subsequent runs against the same model are fast.
5. Confirm the description/keywords populate and auto-save, the same as the Ollama/OpenRouter paths.
