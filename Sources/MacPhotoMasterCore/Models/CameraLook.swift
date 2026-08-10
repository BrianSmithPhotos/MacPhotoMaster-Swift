import Foundation

/// The in-camera creative-dial settings as typed values rather than one flat string.
///
/// `CameraLookParsing` produces this; `summary` renders it back to the string that gets written to
/// IPTC/XMP Instructions. The two exist separately so a look visualiser can draw the individual
/// readings — a hue wheel with the dialled spokes, a tone curve — without parsing the rendered
/// string back apart.
///
/// Only non-default readings are held: every optional being `nil` and every array empty means the
/// mode was named but nothing was dialled in. `CameraLookParsing.parse(from:)` returns `nil` rather
/// than an empty look when there is nothing to report at all.
public struct CameraLook: Hashable {
    /// The chosen-look token (art filter, colour/monochrome profile, Colour Creator) when there is
    /// one, otherwise the plain `PictureMode` name.
    public var mode: String = ""

    /// A named slider reading — the Colour Profile hue spokes and the tone-curve channels share
    /// this shape, a short code and a signed value.
    public struct Slider: Hashable {
        public let code: String
        public let value: Int

        public init(code: String, value: Int) {
            self.code = code
            self.value = value
        }
    }

    /// A stop on the Partial Color ring. `name` falls back to the index when the stop is outside the
    /// measured table, so it is always renderable.
    public struct PartialColor: Hashable {
        public let index: Int
        public let name: String

        public init(index: Int, name: String) {
            self.index = index
            self.name = name
        }
    }

    /// One stacked art-filter option record. Kept as an ordered list because the camera packs these
    /// in field order rather than sorted — a frame can carry `fx` ahead of its `bw filter` — and the
    /// rendered string has to preserve that order.
    public enum ArtEffect: Hashable {
        case bwFilter(String)
        case tint(String)
        case effect(String)
    }

    /// The Colour Creator ring: a position (which is a hue, not an amount) and a bipolar strength.
    public struct ColorCreator: Hashable {
        /// The bottom of the Vivid range, where the render is fully desaturated whatever the
        /// position — see `CameraLookParsing.colorCreatorNames`.
        public static let monochromeStrength = -4

        public let position: Int
        public let name: String
        public let strength: Int

        public var isMonochrome: Bool { strength == Self.monochromeStrength }

        public init(position: Int, name: String, strength: Int) {
            self.position = position
            self.name = name
            self.strength = strength
        }
    }

    /// A monochrome profile's contrast filter and its strength. The camera stores the two
    /// independently, so a filter at strength 0 is inert and never reaches here.
    public struct MonochromeFilter: Hashable {
        public let name: String
        public let strength: Int

        public init(name: String, strength: Int) {
            self.name = name
            self.strength = strength
        }
    }

    public var partialColor: PartialColor?
    public var artEffects: [ArtEffect] = []
    public var colorCreator: ColorCreator?

    public var monochromeFilter: MonochromeFilter?
    public var grain: String?
    /// The Shading Effect wheel, -5...+5 through an unshaded 0. Despite the maker-note tag's name
    /// this is carried by the colour profiles too — see `CameraLookParsing.monochrome`.
    public var shading: Int?
    public var monochromeTint: String?

    /// The Monotone picture mode's own filter and tint — a separate route to the same pair of
    /// settings, which is why these are not folded in with the monochrome-profile ones.
    public var monotoneFilter: String?
    public var monotoneTint: String?

    /// The twelve Colour Profile hue spokes, non-zero ones only, in the camera's own order.
    public var hueSliders: [Slider] = []

    public var contrast: Int?
    public var sharpness: Int?
    public var saturation: Int?
    public var pictureModeEffect: String?

    public var gradation: String?
    /// Whether the camera overrode the tone curve itself, which is independent of the curve.
    public var gradationIsAuto: Bool = false

    public var toneLevels: [Slider] = []

    public init() {}

    /// The readings without the mode, each already rendered, in the order the camera's own settings
    /// menus present them.
    public var segments: [String] {
        var segments: [String] = []

        if let partialColor { segments.append("partial \(partialColor.name)") }
        for effect in artEffects {
            switch effect {
            case .bwFilter(let name): segments.append("bw filter \(name)")
            case .tint(let name): segments.append("tint \(name)")
            case .effect(let name): segments.append("fx \(name)")
            }
        }

        if let colorCreator {
            segments.append("color \(colorCreator.position) (\(colorCreator.name))")
            segments.append(
                colorCreator.isMonochrome
                    ? "vivid -4 (mono)" : "vivid \(Self.signed(colorCreator.strength))")
        }

        if let monochromeFilter {
            segments.append("\(monochromeFilter.name) filter str\(monochromeFilter.strength)")
        }
        if let grain { segments.append("grain \(grain)") }
        if let shading { segments.append("shading \(Self.signed(shading))") }
        if let monochromeTint { segments.append("tint \(monochromeTint)") }

        if let monotoneFilter { segments.append("bw filter \(monotoneFilter)") }
        if let monotoneTint { segments.append("tint \(monotoneTint)") }

        if !hueSliders.isEmpty { segments.append(Self.joined(hueSliders)) }

        if let contrast { segments.append("contrast \(Self.signed(contrast))") }
        if let sharpness { segments.append("sharp \(Self.signed(sharpness))") }
        if let saturation { segments.append("sat \(Self.signed(saturation))") }

        if let pictureModeEffect { segments.append("effect \(pictureModeEffect)") }

        if let gradation { segments.append("grad \(gradation)") }
        if gradationIsAuto { segments.append("grad auto") }

        if !toneLevels.isEmpty { segments.append(Self.joined(toneLevels)) }

        return segments
    }

    /// The mode and its readings as one ` | `-separated line — what gets written to Instructions.
    public var summary: String {
        ([mode] + segments).joined(separator: " | ")
    }

    /// True when the mode was named but nothing non-default was dialled in.
    public var isModeOnly: Bool { segments.isEmpty }

    private static func joined(_ sliders: [Slider]) -> String {
        sliders.map { "\($0.code)\(signed($0.value))" }.joined(separator: " ")
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}
