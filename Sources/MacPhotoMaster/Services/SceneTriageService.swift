import CoreGraphics
import Vision
import os

/// Coarse subject classification via Vision's on-device `VNClassifyImageRequest` — no network, no
/// model download, sub-second — used by `AISuggestionService` only to pick the description word
/// limit and the UI status tag (see `SceneCategory`'s doc comment for why it no longer gates prompt
/// content). Deliberately coarse: this only answers "is the subject a bird/flower", not the species
/// — that's the specialist VLM prompt's job.
enum SceneTriageService {
    /// Real logged confidences for confirmed birds on good subject crops have run 0.19-0.44 — well
    /// under the original 0.4 guess — so this is set low enough to reliably catch them rather than
    /// tuned against a theoretical false-positive rate that hasn't actually been observed.
    private static let confidenceThreshold: VNConfidence = 0.15
    private static let loggedObservationCount = 5
    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "SceneTriage")

    /// Returns `.other` if classification fails or no category clears the confidence threshold —
    /// triage is a prompt-selection hint, never a hard gate on the AI suggestion request. Logs the
    /// top observations either way so a triage miss (e.g. "bird" scoring under threshold behind a
    /// more specific label) is diagnosable from Console instead of guessed at.
    static func classify(_ image: CGImage) -> SceneCategory {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.log(
                "Scene triage request failed: \(error.localizedDescription, privacy: .public)")
            return .other
        }
        guard let observations = request.results else { return .other }

        let topObservations = observations.prefix(loggedObservationCount)
            .map { "\($0.identifier)=\(String(format: "%.2f", $0.confidence))" }
            .joined(separator: ", ")
        // Image dimensions pin down whether this ran on SubjectIsolationService's crop or the
        // fallback full frame — cross-reference against the "SubjectIsolation" log category rather
        // than guessing from the label mix alone.
        logger.log(
            "Scene triage on \(image.width, privacy: .public)x\(image.height, privacy: .public) image, top observations: \(topObservations, privacy: .public)"
        )
        // "bird"/"flower" logged unconditionally (not just when in the top N) so a near-miss —
        // present in the full ~1303-label output but pushed out of the top N by scene labels — is
        // distinguishable from Vision genuinely not seeing it at all.
        for identifier in ["bird", "flower"] {
            if let match = observations.first(where: { $0.identifier == identifier }) {
                logger.log(
                    "Scene triage \(identifier, privacy: .public) confidence: \(String(format: "%.2f", match.confidence), privacy: .public)"
                )
            }
        }

        for observation in observations where observation.confidence >= confidenceThreshold {
            switch observation.identifier {
            case "bird": return .bird
            case "flower": return .flower
            default: continue
            }
        }
        return .other
    }
}
