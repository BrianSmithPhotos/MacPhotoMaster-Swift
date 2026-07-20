import SwiftUI
import UIKit

/// Single tap handler for a grid tile, reporting the tap's held keyboard modifier flags
/// (`UIGestureRecognizer.modifierFlags`, iOS 13.4+ — the iPadOS equivalent of the Mac app's
/// `NSEvent.ModifierFlags`, populated for touches and trackpad clicks alike) so the caller can route
/// a cmd-click/shift-click to multi-select and an unmodified tap to plain single-select.
///
/// This used to be a `Button` (for the plain tap) with a second, modifier-only catcher stacked on
/// top via `.overlay` — but an overlaid `UIViewRepresentable` sits above the `Button` in hit-testing
/// and claims every touch for itself before the `Button`'s own recognizer ever sees it, regardless of
/// what the catcher's recognizer decides to do with that touch. Two competing recognizers for the
/// same tap broke both paths; one recognizer making the whole decision doesn't have that problem.
struct TileTapCatcher: UIViewRepresentable {
    let onTap: (UIKeyModifierFlags) -> Void

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onTap = onTap
        return view
    }

    func updateUIView(_ uiView: CatcherView, context: Context) {
        uiView.onTap = onTap
    }

    final class CatcherView: UIView {
        var onTap: ((UIKeyModifierFlags) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            onTap?(recognizer.modifierFlags)
        }
    }
}
