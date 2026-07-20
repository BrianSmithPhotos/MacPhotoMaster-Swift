import CoreGraphics
import Foundation
import os

/// Backend-agnostic prompting/parsing layer for docs/SPEC.md §6 — takes any `AIProvider` so adding
/// a second backend never touches this file. Ported from the Python reference app's
/// `services/ai_suggestion_service.py`, extended beyond what SPEC.md §6 asks for.
///
/// Callers are expected to run `SubjectIsolationService` on the source image first (the caller does
/// this, rather than `suggest()`, so the isolated crop can be shown in the UI immediately, before the
/// VLM round-trip completes — see `SourceBrowserViewModel.suggestAI()`). `suggest()` runs
/// `SceneTriageService`'s free, on-device classification on whatever `image` it's given, but only to
/// pick the description word limit and the `sceneCategory` tag surfaced in the UI. The species-ID
/// instructions in `buildUserPrompt` are phrased conditionally ("if the subject is a bird...") and
/// sent on every request regardless of triage, because Vision's "bird" confidence on confirmed,
/// well-cropped birds has been observed ranging from 0.08 to 0.44 depending on head/pose visibility —
/// there's no threshold that reliably separates real birds from background scenes, so identification
/// accuracy isn't worth gating on it. Not part of SPEC.md/the Python reference app; added to improve
/// wildlife/plant identification accuracy (e.g. small VLMs conflating similar-looking species) beyond
/// what a single generic prompt gets.
/// Which prompt variant `AISuggestionService` builds. `.full` is the original prompt, written for
/// capable models (all Mac/OpenRouter models, and the Mac app always uses it). `.compact` is a
/// pared-down variant for small on-device models (e.g. FastVLM-0.5B) that otherwise misbehave on the
/// full prompt — they echo its JSON example's placeholder keywords verbatim and don't honor its
/// "if the subject is a bird…" conditional (bird-ID'ing non-wildlife). The iPad selects `.compact`
/// per-model; see `PhotoBrowserViewModel.compactPromptModels`.
public enum PromptProfile {
    case full
    case compact
}

public struct AISuggestionService {
    public init() {}

    private static let systemPrompt =
        "You are a photography metadata assistant. Return only strict JSON with keys description and keywords."
    private static let primaryCompressionQuality: CGFloat = 0.85
    private static let timeoutRetryCropScale: CGFloat = 0.5
    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "AISuggestion")

    /// Sends `image` (the capture-set's AI-source representative) to `provider`/`model`, retrying
    /// once with a center-cropped, lower-effort request if the primary attempt times out or comes
    /// back empty (docs/SPEC.md §6's fallback chain). A retry failure, or any error other than a
    /// timeout/empty response, propagates directly — a real parse/provider error isn't worth
    /// burning a second request on. `birdCandidateSpecies` is `SourceBrowserViewModel`'s eBird
    /// region-species candidate list (see `EBirdCandidateFormatting`) — when non-empty, it gives the
    /// model a verified list of species actually recorded near the photo's GPS fix, rather than
    /// relying on free recall for the Latin binomial.
    public func suggest(
        provider: AIProvider, model: String, image: CGImage, existingDescription: String,
        existingKeywords: String, locationContext: String = "", birdCandidateSpecies: String = "",
        promptProfile: PromptProfile = .full
    ) async throws -> AISuggestionResult {
        try await provider.ensureVisionCapable(model: model)

        let category = SceneTriageService.classify(image)
        let userPrompt = Self.buildUserPrompt(
            existingDescription: existingDescription, existingKeywords: existingKeywords,
            locationContext: locationContext, category: category,
            birdCandidateSpecies: birdCandidateSpecies, promptProfile: promptProfile)

        do {
            var result = try await requestAndParse(
                provider: provider, model: model, image: image, userPrompt: userPrompt, think: true)
            result.sceneCategory = category
            result.evaluatedImage = image
            return result
        } catch let error as AISuggestionError where error == .timeout || error == .emptyResponse {
            guard let cropped = ImageEncoding.centerCrop(image, scale: Self.timeoutRetryCropScale)
            else { throw error }
            var retryResult = try await requestAndParse(
                provider: provider, model: model, image: cropped, userPrompt: userPrompt, think: false)
            retryResult.timeoutRetryAttempted = true
            retryResult.timeoutRetrySucceeded = true
            retryResult.sceneCategory = category
            retryResult.evaluatedImage = cropped
            return retryResult
        }
    }

    private func requestAndParse(
        provider: AIProvider, model: String, image: CGImage, userPrompt: String, think: Bool
    ) async throws -> AISuggestionResult {
        guard
            let jpegData = ImageEncoding.jpegData(
                from: image, compressionQuality: Self.primaryCompressionQuality)
        else { throw AISuggestionError.provider("Could not encode image for AI request") }
        let base64 = jpegData.base64EncodedString()

        let start = Date()
        let responseText = try await provider.chat(
            model: model, systemPrompt: Self.systemPrompt, userPrompt: userPrompt,
            imagePayloads: [base64], think: think)
        Self.logger.log(
            "AI suggestion request: elapsed=\(Date().timeIntervalSince(start), privacy: .public)s imageBytes=\(jpegData.count, privacy: .public)"
        )

        guard let result = Self.parse(responseText) else { throw AISuggestionError.emptyResponse }
        return result
    }

    /// Bird/flower descriptions get more room than the generic 30-word limit to fit a Latin binomial
    /// and a look-alike-species caveat — still well under IPTC `Caption-Abstract`'s legacy 2000-byte
    /// cap (the binding limit, since `ExifToolClient` writes the same string there and to
    /// `XMP-dc:Description`, which has no defined length limit of its own).
    private static let categorizedDescriptionWordLimit = 60
    private static let genericDescriptionWordLimit = 30

    public static func buildUserPrompt(
        existingDescription: String, existingKeywords: String, locationContext: String,
        category: SceneCategory, birdCandidateSpecies: String = "", promptProfile: PromptProfile = .full
    ) -> String {
        switch promptProfile {
        case .full:
            return fullUserPrompt(
                existingDescription: existingDescription, existingKeywords: existingKeywords,
                locationContext: locationContext, category: category,
                birdCandidateSpecies: birdCandidateSpecies)
        case .compact:
            return compactUserPrompt(
                existingDescription: existingDescription, existingKeywords: existingKeywords,
                locationContext: locationContext, category: category,
                birdCandidateSpecies: birdCandidateSpecies)
        }
    }

    /// The original prompt, unchanged — the only variant capable models (Mac/OpenRouter) use. Species-ID
    /// instructions are sent on every request regardless of triage category (see this type's doc comment
    /// for why gating on Vision's bird confidence was rejected for capable models).
    private static func fullUserPrompt(
        existingDescription: String, existingKeywords: String, locationContext: String,
        category: SceneCategory, birdCandidateSpecies: String
    ) -> String {
        let descriptionWordLimit =
            category == .other ? genericDescriptionWordLimit : categorizedDescriptionWordLimit
        var lines = [
            "Describe this photograph for photo metadata.",
            "Return only strict JSON: {\"description\": \"...\", \"keywords\": [\"k1\", \"k2\"]}.",
            "Description: at most \(descriptionWordLimit) words, plain English, no markdown.",
            "Keywords: 10 to 15 lowercase keywords, most specific/identifying terms first.",
            "If the primary subject is a bird, identify the species as precisely as you can and "
                + "include its Latin binomial (genus species) in the description. If more than one "
                + "species is plausible, name the most likely one and mention the field mark "
                + "(plumage, bill shape, size, etc.) that distinguishes it from the next most likely "
                + "look-alike.",
            "If the primary subject is a flower or flowering plant, identify the species as "
                + "precisely as you can and include its Latin binomial (genus species) in the "
                + "description. If more than one species is plausible, name the most likely one and "
                + "mention the distinguishing feature (petal count/shape, color pattern, leaf form, "
                + "etc.).",
            "For any species identification: only give a Latin binomial that is a real, correctly "
                + "spelled genus and species you are confident applies to what's shown — never invent "
                + "one or blend genus/species names from different candidates. If you cannot "
                + "confidently identify the exact species, say so in the description (e.g. name the "
                + "family or genus, or say the exact species is uncertain) instead of guessing a "
                + "specific binomial.",
        ]
        let trimmedDescription = existingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty {
            lines.append("Existing description for context (may be outdated): \(trimmedDescription)")
        }
        let trimmedKeywords = existingKeywords.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKeywords.isEmpty {
            lines.append(
                "Existing keywords already identified for this photo — treat these as a strong, "
                    + "trusted guide (the user has already confirmed them, often from an easier photo "
                    + "of the same subject) and prefer them over an independent guess unless what's "
                    + "shown clearly contradicts them: " + trimmedKeywords)
        }
        let trimmedLocation = locationContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLocation.isEmpty {
            lines.append(
                "Location context (use to improve wildlife/plant identification and habitat "
                    + "plausibility; you may mention city/county/state in the description if it helps): "
                    + trimmedLocation)
            lines.append(
                "If the primary subject is a bird or flower, given that location, strongly prefer a "
                    + "species that is native to or commonly recorded in that region over a visually "
                    + "similar species that isn't found there — only name the non-local species if "
                    + "field marks clearly rule out the locally expected one.")
        }
        let trimmedBirdCandidates = birdCandidateSpecies.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !trimmedBirdCandidates.isEmpty {
            lines.append(
                "If the primary subject is a bird, it has been verified as ever recorded in this "
                    + "location's eBird region. Strongly prefer a species from this list, using its "
                    + "exact common and scientific name as given, over any other species: "
                    + trimmedBirdCandidates)
        }
        return lines.joined(separator: "\n")
    }

    /// Pared-down prompt for small on-device models (e.g. FastVLM-0.5B). Two deliberate differences
    /// from `fullUserPrompt`: (1) the JSON format is described in words with **no example values**, so
    /// a small model can't echo a `["k1","k2"]` placeholder verbatim; (2) the species-ID blocks are
    /// **gated on the triage `category`** rather than sent always — a small model over-applies the
    /// "if it's a bird…" conditional and bird-IDs non-wildlife subjects. Vision triage can miss a
    /// genuine bird, but for small models a missed species ask is a better failure than fabricated
    /// bird descriptions of bridges. Location/existing-context lines are kept (small models still use
    /// them), just terser.
    private static func compactUserPrompt(
        existingDescription: String, existingKeywords: String, locationContext: String,
        category: SceneCategory, birdCandidateSpecies: String
    ) -> String {
        let descriptionWordLimit =
            category == .other ? genericDescriptionWordLimit : categorizedDescriptionWordLimit
        let isBird = category == .bird
        let isFlower = category == .flower
        var lines = [
            "Describe this photograph for photo metadata.",
            "Return only a JSON object with two fields: \"description\" (a string) and \"keywords\" "
                + "(an array of lowercase strings). Output nothing else.",
            "Description: at most \(descriptionWordLimit) words, plain English, no markdown.",
            "Keywords: 10 to 15 specific lowercase keywords for what is actually shown, most "
                + "identifying first.",
        ]
        // Phrased as imperatives, not declaratives ("This is a bird…"): a small model will echo a
        // declarative sentence back as its description verbatim.
        if isBird {
            lines.append(
                "Name the bird's species and its Latin binomial (genus species) in the description. If "
                    + "unsure between look-alikes, give the most likely and mention the distinguishing "
                    + "field mark.")
        }
        if isFlower {
            lines.append(
                "Name the plant's species and its Latin binomial (genus species) in the description. If "
                    + "unsure, give the most likely and mention the distinguishing feature.")
        }
        if isBird || isFlower {
            lines.append(
                "Only give a Latin binomial you are confident is real and correctly spelled. If you "
                    + "cannot identify the exact species, say so (name the genus or family) instead of "
                    + "guessing.")
        }
        let trimmedDescription = existingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty {
            lines.append("Existing description for context (may be outdated): \(trimmedDescription)")
        }
        let trimmedKeywords = existingKeywords.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKeywords.isEmpty {
            lines.append("Existing keywords to prefer unless clearly wrong: \(trimmedKeywords)")
        }
        let trimmedLocation = locationContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLocation.isEmpty {
            lines.append(
                "Location context (you may mention city/county/state in the description if it helps): "
                    + trimmedLocation)
            if isBird || isFlower {
                lines.append(
                    "Given that location, prefer a species native to or commonly recorded there over a "
                        + "similar species not found there, unless field marks clearly rule it out.")
            }
        }
        let trimmedBirdCandidates = birdCandidateSpecies.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if isBird, !trimmedBirdCandidates.isEmpty {
            lines.append(
                "Prefer a species from this verified local list, using its exact common and scientific "
                    + "name as given: " + trimmedBirdCandidates)
        }
        return lines.joined(separator: "\n")
    }

    /// Strips Markdown code fences, tries a direct JSON parse, then falls back to extracting the
    /// first `{...}` region via regex — mirrors the Python reference app's resilient parser, since
    /// local models don't always honor "JSON only" instructions cleanly.
    public static func parse(_ text: String) -> AISuggestionResult? {
        guard let jsonObject = extractJSONObject(from: text) else { return nil }
        guard
            let description = (jsonObject["description"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !description.isEmpty
        else { return nil }
        let keywords = normalizeKeywords(jsonObject["keywords"])
        guard !keywords.isEmpty else { return nil }
        return AISuggestionResult(description: description, keywords: keywords)
    }

    private static func extractJSONObject(from text: String) -> [String: Any]? {
        let stripped = stripCodeFences(text)
        if let data = stripped.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data),
            let object = parsed as? [String: Any]
        {
            return object
        }
        guard
            let range = stripped.range(of: "(?s)\\{.*\\}", options: .regularExpression)
        else { return nil }
        guard let data = String(stripped[range]).data(using: .utf8) else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parsed as? [String: Any]
    }

    private static func stripCodeFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        trimmed.removeFirst(3)
        if let newlineIndex = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: newlineIndex)...])
        }
        if trimmed.hasSuffix("```") {
            trimmed.removeLast(3)
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeKeywords(_ raw: Any?) -> [String] {
        let candidates: [String]
        if let array = raw as? [Any] {
            candidates = array.compactMap { $0 as? String }
        } else if let text = raw as? String {
            candidates = text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init)
        } else {
            candidates = []
        }
        var seenLowercased = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seenLowercased.contains(key) else { continue }
            seenLowercased.insert(key)
            result.append(trimmed)
        }
        return result
    }
}
