import Foundation

/// Which colour-rendering graphic a look calls for — the visualiser's "group 2" (docs/SPEC.md
/// "Ideas, not started"), and the only one of the six groups that is *mutually exclusive*. That
/// exclusivity is what makes one large graphic viable instead of a stack of widgets.
///
/// Two display decisions live here rather than in the view, because both are judgements about the
/// data rather than about layout:
///
/// 1. **The three B&W routes are merged.** A monochrome filter and tint reach the screen by three
///    routes with three different numberings — the art filters' stacked `0x8060`/`0x8070` records,
///    the monochrome profiles' `MonochromeProfileSettings`/`MonochromeColor`, and the Monotone
///    picture mode's `PictureModeBWFilter`/`PictureModeTone`. `CameraLookParsing` must keep them
///    strictly apart (sharing a table would turn orange into red and purple into blue), but they
///    mean the same thing to the eye. The separation is a file-format concern, not a display one.
///
/// 2. **A stale reading loses to the live one.** The camera leaves values behind in tags the current
///    mode doesn't use — a Grainy Film frame carries `"Partial Color 0"`, and a non-zero
///    `ColorProfileSettings` can ride along on an art-filter frame the same way. So this picks by
///    priority rather than asserting only one field is ever populated.
public enum CameraLookRendering: Equatable {
    /// The twelve-spoke Colour Profile wheel: a per-spoke magnitude around the circle. The only
    /// case carrying simultaneous values rather than one selected stop.
    case profileSpokes([CameraLook.Slider])

    /// The 30-position Colour Creator ring: one marker plus a bipolar Vivid strength.
    case colorCreator(CameraLook.ColorCreator)

    /// The 18-stop Partial Color ring: one kept band, whose shoulders and floor depend on which of
    /// the three filter variants shot it.
    case partialColor(stop: Int, name: String, band: CameraLookGeometry.PartialColorBand)

    /// A contrast filter and/or a toning colour, whichever of the three routes supplied them.
    case monochrome(Monochrome)

    /// The mode was named but nothing colour-rendering was dialled in.
    case none

    /// A merged B&W reading. `filterStrength` is `nil` on the routes that don't record one — only
    /// the monochrome profiles carry a separate strength; the art filters and Monotone store the
    /// filter choice alone.
    public struct Monochrome: Equatable {
        public let filter: String?
        public let filterStrength: Int?
        public let tint: String?

        public init(filter: String?, filterStrength: Int?, tint: String?) {
            self.filter = filter
            self.filterStrength = filterStrength
            self.tint = tint
        }

        public var isEmpty: Bool { filter == nil && tint == nil }
    }

    /// Picks the one graphic for a look.
    ///
    /// Priority is Partial Color, then Colour Creator, then monochrome, then the profile spokes.
    /// Partial Color leads because its own tag is the one most often left stale behind another
    /// filter, so a live Partial Color reading is only ever produced when the filter's *name* says
    /// so (`CameraLookParsing.artFilter` gates on that) — while `hueSliders` carries no such gate
    /// and could otherwise outvote it.
    ///
    /// Colour Creator is kept as its own case at Vivid -4 rather than collapsing into `.monochrome`,
    /// even though the output carries no colour there: the cast is applied *before* the
    /// desaturation, so the ring position still decides which hues render light or dark, exactly as
    /// a B&W contrast filter does. Dropping the ring would throw that away.
    public static func rendering(for look: CameraLook) -> CameraLookRendering {
        if let partial = look.partialColor,
            let type = CameraLookGeometry.PartialColorType(mode: look.mode)
        {
            return .partialColor(
                stop: partial.index, name: partial.name,
                band: CameraLookGeometry.partialColorBand(stop: partial.index, type: type))
        }

        if let creator = look.colorCreator { return .colorCreator(creator) }

        let monochrome = merged(look)
        if !monochrome.isEmpty { return .monochrome(monochrome) }

        if !look.hueSliders.isEmpty { return .profileSpokes(look.hueSliders) }

        return .none
    }

    /// The three routes folded into one reading. Checked in the order the parser fills them, and
    /// only one is ever live on a real frame — `PictureModeBWFilter`/`PictureModeTone` read `"n/a"`
    /// outside Monotone, and the profile/art-filter tags are scoped to their own modes.
    private static func merged(_ look: CameraLook) -> Monochrome {
        var filter: String? = look.monochromeFilter?.name ?? look.monotoneFilter
        var strength: Int? = look.monochromeFilter?.strength
        var tint: String? = look.monochromeTint ?? look.monotoneTint

        for effect in look.artEffects {
            switch effect {
            case .bwFilter(let name):
                filter = filter ?? name
            case .tint(let name):
                tint = tint ?? name
            case .effect:
                // A stacked art-filter option (Star Light, Pin Hole, a Shade pairing) is "finish",
                // not colour rendering — it belongs to group 5 and is left for the view to list.
                continue
            }
        }

        // A filter recorded at strength 0 never reaches `CameraLook`, so a strength here without a
        // filter would mean the parser changed; guard rather than draw a strength for nothing.
        if filter == nil { strength = nil }

        return Monochrome(filter: filter, filterStrength: strength, tint: tint)
    }
}
