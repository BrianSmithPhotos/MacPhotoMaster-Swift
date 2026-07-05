import Foundation

/// Coarse subject category from `SceneTriageService`. Species-ID prompt instructions are sent on
/// every `AISuggestionService` request regardless of category (see its doc comment for why); this is
/// used only for the description word limit and the UI status tag, where a wrong guess is low-stakes.
enum SceneCategory: String, Equatable {
    case bird
    case flower
    case other
}
