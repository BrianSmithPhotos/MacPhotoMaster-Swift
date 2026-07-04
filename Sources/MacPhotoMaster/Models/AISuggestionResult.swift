import Foundation

/// A parsed AI-generated description/keywords draft, plus flags recording whether the
/// timeout/empty-response fallback (docs/SPEC.md §6) was needed to get it — surfaced in the
/// Metadata panel's status caption so a slow/degraded response isn't silently indistinguishable
/// from a clean one.
struct AISuggestionResult: Equatable {
    var description: String
    var keywords: [String]
    var timeoutRetryAttempted: Bool = false
    var timeoutRetrySucceeded: Bool = false
}
