import Foundation

/// Where each ring reading sits on a hue circle, for the look visualiser (docs/SPEC.md
/// "Ideas, not started").
///
/// `CameraLookParsing` recovers *what* was dialled; this says *where to draw it*. The two are
/// separate because the parser needs none of this — it renders names into a string — while a view
/// needs an angle for every reading and nothing else.
///
/// Every angle here is a measured sRGB hue in degrees, matching `scripts/make-hue-wheel.py`'s wheel
/// angle by construction, so all three rings share one coordinate system and one background wheel.
/// That is a deliberate choice over reproducing each ring's *detent* geometry: the camera's own UI
/// spaces Colour Creator's 30 positions evenly at 12 degrees, but its rendered output is not evenly
/// spaced in hue at all (positions 16-18 land within 4 degrees of each other while 1-2 are 42
/// apart). Drawing the detents would show the dial; drawing the measured hue shows the picture.
///
/// Provenance for every number below is `scripts/README.md` — "The Colour Profile spokes",
/// "Colour Creator: what is known", and "Partial Color I, II and III are three different things".
public enum CameraLookGeometry {
    // MARK: - Colour Profile spokes

    /// The twelve hue spokes' band centres, keyed by `CameraLookParsing`'s short codes so a parsed
    /// `CameraLook.Slider` maps straight to an angle.
    ///
    /// Measured 2026-08-09 (H1071933-H1071945), one frame per spoke at +5 against an all-zero
    /// reference. Not evenly spaced — gaps run 11.7 to 44.1 degrees — and that unevenness is the
    /// point: yellow through red is four spokes across 72 degrees while the single Green-cyan spans
    /// 73, which is what perceptual hue naming looks like. A wheel drawn at twelve-times-30 would
    /// put every marker in the wrong place.
    ///
    /// Centres come from a luminance shift rather than the saturation change itself (the test wheel
    /// was drawn at S=1 and the camera clips there, so saturation could not rise). Stable to within
    /// 1.7 degrees across three re-measurements, but an indirect estimator — see the caveat in
    /// `scripts/README.md`.
    public static let hueSpokeCenters: [String: Double] = [
        "Y": 42.6, "O": 24.3, "Or": 349.8, "R": 330.7,
        "M": 319.0, "V": 289.5, "B": 245.4, "Bc": 210.2,
        "C": 195.5, "Gc": 157.3, "G": 122.0, "Yg": 78.3,
    ]

    /// The spoke codes in the camera's own order, anticlockwise in increasing index. Ordering the
    /// dictionary above is what lets a view walk the wheel rather than hash order.
    public static let hueSpokeOrder = ["Y", "O", "Or", "R", "M", "V", "B", "Bc", "C", "Gc", "G", "Yg"]

    /// The camera's slider range for a hue spoke, used to scale a reading to a magnitude.
    public static let hueSpokeRange = -5...5

    /// One spoke placed on the circle, carrying the value dialled into it.
    public struct SpokeReading: Equatable {
        public let code: String
        public let hue: Double
        public let value: Int

        public init(code: String, hue: Double, value: Int) {
            self.code = code
            self.hue = hue
            self.value = value
        }
    }

    /// All twelve spokes in hue order, with the parsed values filled in and everything else at zero.
    ///
    /// `CameraLookParsing` emits only the spokes that were moved, which is right for a summary
    /// string and wrong for a shape: a closed figure needs a value at every vertex, and an absent
    /// spoke means zero rather than missing. Sorted by hue rather than by the camera's own order so
    /// a caller can walk the circle and interpolate without re-sorting.
    public static func spokeReadings(_ sliders: [CameraLook.Slider]) -> [SpokeReading] {
        let dialled = Dictionary(sliders.map { ($0.code, $0.value) }, uniquingKeysWith: { _, last in last })
        return hueSpokeOrder
            .compactMap { code -> SpokeReading? in
                guard let hue = hueSpokeCenters[code] else { return nil }
                return SpokeReading(code: code, hue: hue, value: dialled[code] ?? 0)
            }
            .sorted { $0.hue < $1.hue }
    }

    /// The dialled value at an arbitrary hue, linearly interpolated between the two spokes either
    /// side of it and wrapping across 0/360.
    ///
    /// The camera's bands overlap and blend rather than switching at a boundary, so a continuous
    /// value is closer to what the sensor pipeline does than a nearest-spoke lookup, which would
    /// draw twelve hard steps the camera never produces. Interpolation runs in angle, so the uneven
    /// spoke spacing carries through: the 44-degree Violet-to-Blue gap blends slowly and the
    /// 11.7-degree Red-to-Magenta gap turns over sharply.
    public static func interpolatedSpokeValue(at hue: Double, readings: [SpokeReading]) -> Double {
        guard readings.count > 1 else { return Double(readings.first?.value ?? 0) }

        let target = normalized(hue)
        // No reading at or below the target means it sits in the wrapped gap below the first spoke,
        // whose lower neighbour is the last one.
        let lowerIndex = readings.lastIndex { $0.hue <= target } ?? readings.count - 1
        let lower = readings[lowerIndex]
        let upper = readings[(lowerIndex + 1) % readings.count]

        let span = normalized(upper.hue - lower.hue)
        guard span > 0 else { return Double(lower.value) }

        let position = normalized(target - lower.hue) / span
        return Double(lower.value) + (Double(upper.value) - Double(lower.value)) * position
    }

    // MARK: - Partial Color

    /// Stop 0's measured centre. Pure yellow is 60 and the camera's own ring UI draws a yellow
    /// selector at top, which fixes the anchor independently of the pixels.
    public static let partialColorStopZero: Double = 64.1

    /// Hue change per stop, measured at 20.0 degrees and running *down* in hue with the index.
    public static let partialColorStopStep: Double = -20.0

    public static let partialColorStopCount = 18

    /// The hue kept by a given stop of the Partial Color ring.
    public static func partialColorCenter(stop: Int) -> Double {
        normalized(partialColorStopZero + partialColorStopStep * Double(stop))
    }

    /// Which of the three Partial Color filters is in play. The camera writes no separate field for
    /// this — the variant is part of the filter's own name, so it comes from `CameraLook.mode`.
    public enum PartialColorType: Equatable {
        case one, two, three

        /// `"Partial Color"`, `"Partial Color II"`, `"Partial Color III"` — exiftool's PrintConv
        /// text, which is what `ArtFilterTokenParsing` puts in `CameraLook.mode`. Matched on the
        /// numeral suffix rather than by prefix, since `"Partial Color II"` prefixes `"...III"`.
        public init?(mode: String) {
            switch mode.trimmingCharacters(in: .whitespaces) {
            case "Partial Color": self = .one
            case "Partial Color II": self = .two
            case "Partial Color III": self = .three
            default: return nil
            }
        }
    }

    /// The sector a Partial Color filter keeps, as a shape to draw rather than a single marker.
    public struct PartialColorBand: Equatable {
        /// Kept hue, degrees.
        public let center: Double
        /// Full width at half maximum, degrees.
        public let width: Double
        /// The 90%-to-10% shoulder fall, degrees — how hard the edge of the sector is.
        public let edge: Double
        /// Chroma retained everywhere *outside* the band, 0-1. Non-zero only for type II.
        public let floor: Double

        public init(center: Double, width: Double, edge: Double, floor: Double) {
            self.center = center
            self.width = width
            self.edge = edge
            self.floor = floor
        }
    }

    /// Measured 2026-08-09 (H1071970-H1071978), three types at each of three stops.
    ///
    /// The three share one band width and differ at the shoulders and in the floor. That reading
    /// needs a word, because the raw table in `scripts/README.md` appears to show type II with a
    /// much wider band (76 degrees mean) and a far softer edge (76 against I's 20). Both are
    /// artefacts of normalising a floored curve to its own peak: with a floor `f`, half-maximum
    /// falls at `(0.5 - f)/(1 - f)` of the underlying lobe — 0.40 at II's f=0.17, so the measured
    /// "FWHM" is really the lobe's 40% width and reads wide. The 10% level sits *below* the floor
    /// entirely and is never crossed, so II's "90-to-10" fall of 98-107 degrees is measuring the
    /// tail settling onto the floor, not a shoulder. Removing the floor leaves I's band, which is
    /// what `scripts/README.md` concludes and what is encoded here.
    ///
    /// Width is the pooled I+III mean (62, 70, 62, 66, 70, 64). Per-type widths would claim a
    /// precision three stops each cannot support.
    public static func partialColorBand(stop: Int, type: PartialColorType) -> PartialColorBand {
        let center = partialColorCenter(stop: stop)
        switch type {
        case .one:
            return PartialColorBand(center: center, width: 66, edge: 20, floor: 0)
        case .two:
            return PartialColorBand(center: center, width: 66, edge: 20, floor: 0.17)
        case .three:
            return PartialColorBand(center: center, width: 66, edge: 10, floor: 0)
        }
    }

    /// How much chroma a Partial Color band leaves standing at a given hue, 0-1.
    ///
    /// A linear shoulder centred on the half-width, scaled so the 90%-to-10% fall spans exactly the
    /// measured `edge`, then lifted onto the floor. Two properties are load-bearing and both are
    /// asserted in the tests: response is exactly 0.5 at the half-width (that is what FWHM *means*,
    /// so a band drawn any other way would not be the band that was measured), and the fall from
    /// 0.9 to 0.1 spans `edge` rather than some multiple of it.
    ///
    /// The floor is the whole of what separates type II from types I and III — see
    /// `partialColorBand(stop:type:)`.
    public static func retainedChroma(_ band: PartialColorBand, at hue: Double) -> Double {
        let distance = angularDistance(hue, band.center)
        let half = band.width / 2

        let response: Double
        if band.edge <= 0 {
            response = distance <= half ? 1 : 0
        } else {
            response = min(max((half + 0.625 * band.edge - distance) / (1.25 * band.edge), 0), 1)
        }

        return band.floor + (1 - band.floor) * response
    }

    /// The shorter way round the circle between two hues, 0-180.
    public static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let delta = normalized(a - b)
        return min(delta, 360 - delta)
    }

    // MARK: - Colour Creator

    /// The hue each of the ring's 30 positions casts toward, or `nil` at position 0, which imposes
    /// no hue at all and runs as a pure saturation control (0.36% measured saturation, and its JPEG
    /// white balance equals the ORF's exactly).
    ///
    /// Measured 2026-08-09 (H1071885-H1071915) at Vivid -1 against a flat neutral wall, reading the
    /// cast off the mean patch with position 0 as reference white. Two caveats carried from
    /// `scripts/README.md`: positions 3-5 (13, 21, 14) are not monotonic and the wobble is framing
    /// noise, and the low-chroma positions (1-5, 26-29) carry the most angular uncertainty because
    /// cast saturation runs 17% at the yellow-green ends against 45% at blue. Repeatability is
    /// bracketed at 2.4 degrees by a duplicate shot at position 3.
    public static func colorCreatorHue(position: Int) -> Double? {
        guard colorCreatorHues.indices.contains(position) else { return nil }
        return colorCreatorHues[position]
    }

    /// `nil` at index 0 — neutral, no hue. See `colorCreatorHue(position:)`.
    private static let colorCreatorHues: [Double?] = [
        nil, 74, 32, 13, 21, 14, 358, 339, 324, 302,
        282, 260, 248, 243, 227, 218, 214, 210, 210, 202,
        194, 186, 177, 166, 150, 132, 113, 100, 96, 90,
    ]

    public static let colorCreatorPositionCount = 30

    /// The Vivid axis, which is bipolar saturation rather than an intensity of the cast: -4 is exact
    /// monochrome, 0 sits at the untouched reference, +3 boosts.
    public static let colorCreatorStrengthRange = -4...3

    // MARK: - Shared

    /// Folds an angle into 0..<360 so the tables above can be written as measured and the
    /// arithmetic in `partialColorCenter(stop:)` can run negative without special-casing.
    public static func normalized(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}
