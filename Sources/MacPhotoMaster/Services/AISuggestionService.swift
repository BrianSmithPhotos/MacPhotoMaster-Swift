import CoreGraphics
import Foundation
import os

/// Backend-agnostic prompting/parsing layer for docs/SPEC.md §6 — takes any `AIProvider` so adding
/// a second backend never touches this file. Ported from the Python reference app's
/// `services/ai_suggestion_service.py`, narrowed to what SPEC.md §6 actually asks for (no
/// subject-crop refinement pass — that's a Python-app-only quality heuristic, not in this app's spec).
struct AISuggestionService {
    private static let systemPrompt =
        "You are a photography metadata assistant. Return only strict JSON with keys description and keywords."
    private static let primaryCompressionQuality: CGFloat = 0.85
    private static let timeoutRetryCropScale: CGFloat = 0.5
    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "AISuggestion")

    /// Sends `image` (the capture-set's AI-source representative) to `provider`/`model`, retrying
    /// once with a center-cropped, lower-effort request if the primary attempt times out or comes
    /// back empty (docs/SPEC.md §6's fallback chain). A retry failure, or any error other than a
    /// timeout/empty response, propagates directly — a real parse/provider error isn't worth
    /// burning a second request on.
    func suggest(
        provider: AIProvider, model: String, image: CGImage, existingDescription: String,
        existingKeywords: String, locationContext: String = ""
    ) async throws -> AISuggestionResult {
        try await provider.ensureVisionCapable(model: model)

        let userPrompt = Self.buildUserPrompt(
            existingDescription: existingDescription, existingKeywords: existingKeywords,
            locationContext: locationContext)

        do {
            return try await requestAndParse(
                provider: provider, model: model, image: image, userPrompt: userPrompt, think: true)
        } catch let error as AISuggestionError where error == .timeout || error == .emptyResponse {
            guard let cropped = ImageEncoding.centerCrop(image, scale: Self.timeoutRetryCropScale) else {
                throw error
            }
            var retryResult = try await requestAndParse(
                provider: provider, model: model, image: cropped, userPrompt: userPrompt, think: false)
            retryResult.timeoutRetryAttempted = true
            retryResult.timeoutRetrySucceeded = true
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

    private static func buildUserPrompt(
        existingDescription: String, existingKeywords: String, locationContext: String
    ) -> String {
        var lines = [
            "Describe this photograph for photo metadata.",
            "Return only strict JSON: {\"description\": \"...\", \"keywords\": [\"k1\", \"k2\"]}.",
            "Description: at most 30 words, plain English, no markdown.",
            "Keywords: 10 to 15 lowercase keywords, most specific/identifying terms first.",
        ]
        let trimmedDescription = existingDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty {
            lines.append("Existing description for context (may be outdated): \(trimmedDescription)")
        }
        let trimmedKeywords = existingKeywords.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKeywords.isEmpty {
            lines.append("Existing keywords for context: \(trimmedKeywords)")
        }
        let trimmedLocation = locationContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLocation.isEmpty {
            lines.append(
                "Location context (use to improve wildlife/plant identification and habitat "
                    + "plausibility; you may mention city/county/state in the description if it helps): "
                    + trimmedLocation)
        }
        return lines.joined(separator: "\n")
    }

    /// Strips Markdown code fences, tries a direct JSON parse, then falls back to extracting the
    /// first `{...}` region via regex — mirrors the Python reference app's resilient parser, since
    /// local models don't always honor "JSON only" instructions cleanly.
    static func parse(_ text: String) -> AISuggestionResult? {
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
