import CoreGraphics
import Foundation
import ImageIO
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// `AIProvider` backend for Apple's on-device Foundation Models, using `@Generable` guided
/// generation so the model returns a *type-safe* `{description, keywords, species}` value rather
/// than JSON text we have to hope is well-formed — the recurring failure mode of the small
/// text-only providers (see docs/MLX_PROVIDER.md). Nothing leaves the device.
///
/// It still plugs into the shared `chat -> String` seam: the typed result is serialized to strict
/// JSON here and handed back for `AISuggestionService.parse()` to decode, so no protocol change is
/// needed and the guaranteed-structure win is retained (we serialize a value we know is valid). The
/// caller selects `PromptProfile.guided`, whose user prompt drops the "return JSON" framing and
/// instead points the model at the typed `species` field.
///
/// Requires the macOS 27 / iOS 27 SDK (Xcode-beta) to build — image input to Foundation Models is
/// only present there; the whole repo is built with `DEVELOPER_DIR` pointed at Xcode-beta for this
/// reason (see `scripts/build-app-bundle.sh` and CLAUDE.md). At runtime the OS floor is enforced by
/// the `#available` check below, so an older OS gets a clear `.provider(...)` error rather than a
/// crash.
public struct FoundationModelsProvider: AIProvider {
    public init() {}

    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "AISuggestion")

    /// Instructions given to the `LanguageModelSession`. Deliberately not the caller's `systemPrompt`
    /// (which is the shared "return only strict JSON" line) — telling a guided-generation model to
    /// emit JSON makes it write JSON text into the description string. The `@Generable` schema owns
    /// the output shape; these instructions only shape identification behavior.
    private static let instructions =
        "You are a photography metadata assistant. Identify the subject precisely and fill in the "
        + "description, keywords and species fields. For a bird or flowering plant that you can "
        + "confidently identify, give its species and include its Latin binomial in the description; "
        + "if you are unsure of the exact species, leave the species field empty rather than guessing."

    #if canImport(FoundationModels)
    @available(macOS 27.0, iOS 27.0, *)
    @Generable
    struct PhotoMetadata {
        @Guide(description: "One plain-English sentence describing the photograph, no markdown.")
        var description: String

        @Guide(description: "10 to 15 specific lowercase keywords for what is actually shown, most identifying first.")
        var keywords: [String]

        @Guide(description: "If the main subject is a bird or flowering plant you can confidently identify, its species common name; otherwise an empty string.")
        var species: String
    }
    #endif

    /// There's one on-device system model, so the `model` segment (`foundation:apple`) is nominal —
    /// the real check is whether Foundation Models is usable on this machine right now (OS floor +
    /// Apple Intelligence enabled + model downloaded). Surfacing the specific unavailability reason
    /// here means the Metadata panel status caption tells the user what to fix.
    public func ensureVisionCapable(model: String) async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 27.0, iOS 27.0, *) else {
            throw AISuggestionError.provider(
                "Apple Foundation Models image input requires macOS 27 or iOS 27")
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw AISuggestionError.provider(Self.message(for: reason))
        }
        #else
        throw AISuggestionError.provider(
            "This build was not compiled with the Foundation Models framework")
        #endif
    }

    /// `think` is a no-op: guided generation has no effort knob, and `AISuggestionService`'s retry
    /// path already lowers effort by re-sending a center-cropped image. `systemPrompt` is ignored in
    /// favor of `Self.instructions` (see that property's note).
    public func chat(
        model: String, systemPrompt: String, userPrompt: String, imagePayloads: [String], think: Bool
    ) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 27.0, iOS 27.0, *) else {
            throw AISuggestionError.provider(
                "Apple Foundation Models image input requires macOS 27 or iOS 27")
        }
        guard let payload = imagePayloads.first else {
            throw AISuggestionError.provider("No image supplied for Foundation Models request")
        }
        guard let image = Self.decodeImage(base64: payload) else {
            throw AISuggestionError.provider("Could not decode image for Foundation Models request")
        }

        let start = Date()
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = Prompt {
                userPrompt
                Attachment(image)
            }
            let response = try await session.respond(to: prompt, generating: PhotoMetadata.self)
            try Task.checkCancellation()
            Self.logger.log(
                "Foundation Models chat: elapsed=\(Date().timeIntervalSince(start), privacy: .public)s"
            )
            return try Self.serialize(response.content)
        } catch let error as AISuggestionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AISuggestionError.provider(
                "Foundation Models generation failed: \(error.localizedDescription)")
        }
        #else
        throw AISuggestionError.provider(
            "This build was not compiled with the Foundation Models framework")
        #endif
    }

    #if canImport(FoundationModels)
    /// Re-encodes the typed result as strict JSON so it crosses the shared `chat -> String` seam and
    /// is decoded by `AISuggestionService.parse()` like any other provider's output — the difference
    /// being this JSON is serialized from a value the schema already guaranteed, not scraped from
    /// free-form model text.
    @available(macOS 27.0, iOS 27.0, *)
    private static func serialize(_ metadata: PhotoMetadata) throws -> String {
        let object: [String: Any] = [
            "description": metadata.description,
            "keywords": metadata.keywords,
            "species": metadata.species,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AISuggestionError.provider("Could not serialize Foundation Models result")
        }
        return json
    }
    #endif

    /// Decodes the base64 JPEG payload `AISuggestionService` produces into a `CGImage`. Extracted so
    /// it's unit-testable without a Foundation Models session (which needs a real device).
    public static func decodeImage(base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    #if canImport(FoundationModels)
    @available(macOS 27.0, iOS 27.0, *)
    private static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled — turn it on in System Settings"
        case .deviceNotEligible:
            return "This device is not eligible for Apple Foundation Models"
        case .modelNotReady:
            return "The on-device model is still downloading — try again shortly"
        @unknown default:
            return "Apple Foundation Models is unavailable"
        }
    }
    #endif
}
