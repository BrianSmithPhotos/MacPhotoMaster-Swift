import CoreGraphics
import Foundation

/// A parsed AI-generated description/keywords draft, plus flags recording whether the
/// timeout/empty-response fallback (docs/SPEC.md §6) was needed to get it — surfaced in the
/// Metadata panel's status caption so a slow/degraded response isn't silently indistinguishable
/// from a clean one.
public struct AISuggestionResult: Equatable {
    public var description: String
    public var keywords: [String]
    public var timeoutRetryAttempted: Bool = false
    public var timeoutRetrySucceeded: Bool = false
    /// `SceneTriageService`'s pre-request classification, surfaced so testing can correlate
    /// identification accuracy with which prompt variant was actually used.
    public var sceneCategory: SceneCategory = .other
    /// The exact image sent to the model (after `SubjectIsolationService` cropping, when it found a
    /// salient instance) — surfaced so the Metadata panel can show what was actually evaluated, since
    /// a misidentification is only diagnosable if you know whether the crop or the original frame was
    /// the input. Excluded from `Equatable` below: `CGImage` doesn't conform, and tests only care
    /// about the text/category fields.
    public var evaluatedImage: CGImage?

    public static func == (lhs: AISuggestionResult, rhs: AISuggestionResult) -> Bool {
        lhs.description == rhs.description && lhs.keywords == rhs.keywords
            && lhs.timeoutRetryAttempted == rhs.timeoutRetryAttempted
            && lhs.timeoutRetrySucceeded == rhs.timeoutRetrySucceeded && lhs.sceneCategory == rhs.sceneCategory
    }
}
