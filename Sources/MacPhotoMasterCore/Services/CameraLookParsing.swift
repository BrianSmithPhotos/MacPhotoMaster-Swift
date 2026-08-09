import Foundation

/// Builds the human-readable "camera look" string from `exiftool`'s raw JSON metadata dict — the
/// in-camera creative-dial settings (colour/monochrome profile sliders, Colour Creator colour and
/// strength, mono filter, grain, shading, tone curve) that no standard EXIF tag carries.
///
/// This exists because the OM-3 records *what you dialled in*, not *which slot you dialled it in*.
/// The profile slots are scratchpads whose contents get overwritten in place, so "Colour Profile 2"
/// names nothing durable — only the parameter values are ground truth, and only in the JPEG. The
/// ORF deliberately stays at the neutral mode-dial value so a later RAW edit isn't pre-committed to
/// the in-camera look, which is why this is read per-file rather than per-capture-set.
///
/// The camera's own `*` "this profile has been edited" indicator is *not* recoverable: it is a
/// comparison against the slot's saved baseline, and the file only ever carries the current values.
/// Recording the values themselves makes the flag redundant.
///
/// Parses `exiftool`'s PrintConv *text*, not raw numbers, because `ExifToolClient.readArguments`
/// deliberately omits `-n` — so these maker-note arrays arrive as semicolon-separated strings like
/// `"Red Filter; 0; 8; Strength 3; 0; 3"`, with the camera's slider min/max padded in between the
/// actual readings. Each parser below documents the layout it's indexing into.
///
/// Defaults are suppressed so the string stays short enough for the legacy IPTC IIM
/// `SpecialInstructions` 256-character cap — see `MetadataWriter`'s paired IIM/XMP write.
public enum CameraLookParsing {
    /// Short codes for `ColorProfileSettings`' 12 hue sliders, in the order the camera writes them
    /// (Yellow, Orange, Orange-red, Red, Magenta, Violet, Blue, Blue-cyan, Cyan, Green-cyan, Green,
    /// Yellow-green). Abbreviated because all 12 dialled at once has to fit the IIM cap.
    private static let hueCodes = ["Y", "O", "Or", "R", "M", "V", "B", "Bc", "C", "Gc", "G", "Yg"]

    private static let toneCodes = ["Highlights": "HL", "Shadows": "SH", "Midtones": "Mid"]

    /// The rendered line for IPTC/XMP Instructions. Returns `""` when nothing non-default was
    /// dialled in, so the caller can skip the write entirely rather than stamping an empty field.
    ///
    /// This is `parse(from:)` rendered — reach for that instead when the individual readings are
    /// wanted rather than the line.
    public static func look(from metadata: [String: Any]) -> String {
        parse(from: metadata)?.summary ?? ""
    }

    /// Reads the dial settings into typed values, or `nil` when there is nothing to report.
    ///
    /// The mode is `ArtFilterTokenParsing`'s chosen-look token when there is one (art filter,
    /// colour/monochrome profile, Colour Creator), and otherwise the plain `PictureMode` name.
    /// Plain modes are reported because they are not all neutral — Muted, Monotone, Underwater and
    /// i-Enhance are distinct renderings, and they carry their own contrast/sharpness/saturation,
    /// `PictureModeEffect` and `Gradation`, none of which was recorded before. Only Natural with
    /// nothing dialled stays silent, which is what keeps Instructions off an ordinary frame.
    ///
    /// The camera's Custom picture mode is deliberately not looked for: it is a container that
    /// holds one of the base renderings, and the file records only the base it resolved to. A full
    /// maker-note scan of a Custom/i-Enhance frame shows no slot index or flag anywhere — the same
    /// "records what you dialled, not which slot you dialled it in" behaviour as the profiles.
    public static func parse(from metadata: [String: Any]) -> CameraLook? {
        let chosenLook = ArtFilterTokenParsing.token(from: metadata)
        let pictureMode = fields(metadata, "Olympus:PictureMode").first ?? ""
        let mode = chosenLook.isEmpty ? pictureMode : chosenLook
        guard !mode.isEmpty else { return nil }

        var look = CameraLook()
        look.mode = mode
        artFilter(metadata, into: &look)
        colorCreator(metadata, into: &look)
        monochrome(metadata, into: &look)
        monotone(metadata, into: &look)
        colorProfile(metadata, into: &look)
        contrastSharpnessSaturation(metadata, into: &look)
        pictureModeEffect(metadata, into: &look)
        gradation(metadata, into: &look)
        tone(metadata, into: &look)

        if look.isModeOnly, chosenLook.isEmpty, pictureMode == "Natural" { return nil }
        return look
    }

    /// The stacked-option record codes. `0x8060` is the B&W contrast filter (which colours render
    /// light or dark) and `0x8070` the toning colour applied to the finished monochrome — two
    /// separate darkroom stages, and the camera stores them independently. Proven on a controlled
    /// set: holding the filter at green while moving the tint sepia→green changes only the `0x8070`
    /// record, and holding the tint at green while moving the filter green→yellow changes only the
    /// `0x8060` record.
    private static let bwFilterRecord = 0x8060
    private static let tintRecord = 0x8070

    /// exiftool names neither record's values, so both tables live here. Note these are *not* the
    /// same numbering as `PictureModeBWFilter`/`PictureModeTone`, which cover the identical two
    /// option lists offset by one — see `monotone(_:into:)`.
    private static let artBWFilters = ["none", "yellow", "orange", "red", "green"]
    private static let artTints = ["normal", "sepia", "blue", "purple", "green"]

    /// The names exiftool does supply are its own; `0x80a0`/`0x80a1` it has no table for at all, so
    /// those two were measured (2026-08-09, H1071930/H1071931). Shading darkens two opposite edges,
    /// which reads straight off the pixels: `0x80a1` takes the top and bottom bands to 67% of centre
    /// luminance while leaving left and right at 110%, and `0x80a0` does the reverse (64% / 117%).
    /// The known Blur Left and Right frame darkens nothing (128-134%), which is what separates the
    /// two effects — Blur removes detail, Shade removes light.
    ///
    /// Note the pairing is the opposite way round from Blur's: `0x8080` is top/bottom and `0x8081`
    /// left/right, but `0x80a0` is left/right and `0x80a1` top/bottom. Extrapolating the Blur order
    /// would have named both backwards, which is why this was measured rather than inferred.
    private static let artEffectCodes: [String: Int] = [
        "No Effect": 0x0000, "Star Light": 0x8010, "Pin Hole": 0x8020, "Frame": 0x8030,
        "Soft Focus": 0x8040, "White Edge": 0x8050, "B&W": 0x8060,
        "Blur Top and Bottom": 0x8080, "Blur Left and Right": 0x8081,
        "Shade Left and Right": 0x80A0, "Shade Top and Bottom": 0x80A1,
    ]

    /// exiftool's colour-filter PrintConv, inverted. Field 6 always arrives as this text whatever
    /// the record's code actually means, so it has to be turned back into a number before the code
    /// can say how to read it.
    private static let colorFilterTexts: [String: Int] = [
        "No Color Filter": 0, "Yellow Color Filter": 1, "Orange Color Filter": 2,
        "Red Color Filter": 3, "Green Color Filter": 4,
    ]

    /// The Partial Color ring's 18 stops. exiftool has no table for these — its PrintConv is
    /// literally `"Partial Color $val"` — so the mapping was measured: a hue wheel was shot once at
    /// every stop and the surviving sector's position on the wheel read off geometrically. Stop 0 is
    /// yellow and each further stop moves 20 degrees *down* in hue, so the ring runs
    /// yellow, orange, red, magenta, blue, cyan, green and back. The camera's own ring UI puts a
    /// yellow selector at the top, which independently fixes stop 0 against the measured anchor of
    /// 64 degrees (pure yellow is 60).
    private static let partialColorNames = [
        "yellow", "amber", "orange", "red", "crimson", "pink",
        "magenta", "purple", "violet", "blue", "azure", "sky",
        "cyan", "turquoise", "emerald", "green", "lime", "chartreuse",
    ]

    private static func partialColorName(_ index: Int) -> String {
        partialColorNames.indices.contains(index) ? partialColorNames[index] : "\(index)"
    }

    /// The Colour Creator ring's 30 positions. Like Partial Color, exiftool has no table for these,
    /// so they were measured (2026-08-09, OM-3, frames H1071885-H1071915): every position shot at
    /// Vivid -1 against a flat neutral wall at locked exposure, reading the cast off the mean patch
    /// with position 0 as the reference white.
    ///
    /// Position 0 is *neutral* — it applies no hue at all (0.36% saturation, and its recorded JPEG
    /// white balance equals the ORF's exactly). It still runs as a pure saturation control, which is
    /// why it is reported rather than suppressed. Positions 1-29 then run yellow-green, orange, red,
    /// magenta, blue, cyan, green and back, hue decreasing with the index — the same direction as
    /// the Partial Color ring.
    ///
    /// Names repeat where the measurement says they should. The ring's detents are 12 degrees apart
    /// geometrically (confirmed from OM Workspace, which labels the ring 0/5/10/15/20/25 clockwise
    /// from 12 o'clock, and whose cursor for position 11 sits at 131 degrees against 132 predicted),
    /// but the rendered output is not evenly spaced in hue: positions 16-18 all land within 4
    /// degrees of each other, while 1-2 are 42 degrees apart. Inventing 29 distinct names would
    /// claim a precision the camera does not deliver.
    private static let colorCreatorNames = [
        "neutral", "yellow-green", "orange", "vermilion", "vermilion", "vermilion",
        "red", "crimson", "rose", "magenta", "purple",
        "violet", "indigo", "indigo", "blue", "blue",
        "azure", "azure", "azure", "sky", "sky",
        "cyan", "cyan", "turquoise", "jade", "emerald",
        "green", "lime", "lime", "lime",
    ]

    private static func colorCreatorName(_ index: Int) -> String {
        colorCreatorNames.indices.contains(index) ? colorCreatorNames[index] : "\(index)"
    }

    /// `ArtFilterEffect` is 20 int16u values: the filter itself in fields 0-3, then up to four
    /// stacked-option records of `(code, marker, value, unused)` packed from field 4 in ascending
    /// code order and zero-padded. The markers are the camera's usual min/max padding and carry no
    /// reading.
    ///
    /// exiftool applies a PrintConv only to fields 0, 3, 4 and 6, which makes 4 and 6 look like
    /// fixed "effect" and "colour filter" slots. They are not — they are the *first stacked
    /// record's* code and value, and what field 6 means depends entirely on the code in field 4.
    /// On a tint-only frame the `0x8070` record lands at field 4 and exiftool renders its value
    /// through the colour-filter table anyway: value 3 is a purple tint but prints as
    /// `"Red Color Filter"`. Confirmed by writing that array to a scratch copy and reading it back,
    /// which is why the code is dispatched on and the position never is.
    private static func artFilter(_ metadata: [String: Any], into look: inout CameraLook) {
        let fields = self.fields(metadata, "Olympus:ArtFilterEffect")
        guard fields.count >= 8, !fields[0].isEmpty, fields[0] != "Off" else { return }

        // Partial colour is a stale leftover on anything but a Partial Color variant — Grainy Film
        // frames carry "Partial Color 0" despite the filter having no such setting — so this is
        // gated on the filter's name rather than on the value being non-zero.
        if fields[0].hasPrefix("Partial Color"), let index = trailingInt(fields[3]) {
            look.partialColor = CameraLook.PartialColor(
                index: index, name: partialColorName(index))
        }

        for start in stride(from: 4, to: fields.count - 2, by: 4) {
            guard let record = stackedRecord(fields, at: start), record.code != 0 else { continue }
            switch record.code {
            case bwFilterRecord:
                if record.value != 0 {
                    look.artEffects.append(.bwFilter(optionName(artBWFilters, record.value)))
                }
            case tintRecord:
                if record.value != 0 {
                    look.artEffects.append(.tint(optionName(artTints, record.value)))
                }
            default:
                look.artEffects.append(.effect(artEffectName(record.code)))
            }
        }
    }

    /// The record at field 4 arrives PrintConv'd — its code as a name and its value through the
    /// colour-filter table — while every later record is plain numbers. Both are normalised here so
    /// the caller only ever sees `(code, value)`.
    private static func stackedRecord(_ fields: [String], at start: Int) -> (code: Int, value: Int)? {
        guard start > 4 else {
            guard let code = artEffectCode(fields[4]), let value = colorFilterTexts[fields[6]]
            else { return nil }
            return (code, value)
        }
        guard let code = Int(fields[start]), let value = Int(fields[start + 2]) else { return nil }
        return (code, value)
    }

    /// A code exiftool has no name for prints as `"Unknown (0x8070)"` — the tint record is exactly
    /// that case, so the hex is recovered rather than the record being dropped.
    private static func artFilterCodeHex(_ field: String) -> Int? {
        guard field.hasPrefix("Unknown (0x"), let tail = field.split(separator: "x").last
        else { return nil }
        return Int(tail.dropLast(), radix: 16)
    }

    private static func artEffectCode(_ field: String) -> Int? {
        artEffectCodes[field] ?? artFilterCodeHex(field)
    }

    private static func artEffectName(_ code: Int) -> String {
        artEffectCodes.first { $0.value == code }?.key ?? String(format: "0x%04x", code)
    }

    private static func optionName(_ names: [String], _ value: Int) -> String {
        names.indices.contains(value) ? names[value] : "\(value)"
    }

    /// `PictureModeBWFilter` and `PictureModeTone` are the *Monotone picture mode's* own filter and
    /// tint — a third place the same pair of settings can live, alongside the monochrome profiles'
    /// `MonochromeProfileSettings`/`MonochromeColor` and the art filters' stacked records. Only one
    /// route is ever live: these two read `"n/a"` outside Monotone, so no mode gate is needed.
    ///
    /// Read as text rather than through `artBWFilters`/`artTints`, because these cover the same two
    /// option lists offset by one — art-filter yellow is 1 where here it is 2 — and sharing a table
    /// would silently turn orange into red and purple into blue.
    private static func monotone(_ metadata: [String: Any], into look: inout CameraLook) {
        let filter = text(metadata, "Olympus:PictureModeBWFilter")
        if !filter.isEmpty, filter != "n/a", filter != "Neutral" {
            look.monotoneFilter = filter.lowercased()
        }

        let tone = text(metadata, "Olympus:PictureModeTone")
        if !tone.isEmpty, tone != "n/a", tone != "Neutral" {
            look.monotoneTint = tone.lowercased()
        }
    }

    /// The i-Enhance strength, `"Low"`/`"Standard"`/`"High"`. Standard is the default. Only one
    /// frame in the 126 sampled is anything else, so this would never have surfaced without a shot
    /// taken deliberately to exercise it.
    private static func pictureModeEffect(_ metadata: [String: Any], into look: inout CameraLook) {
        let effect = text(metadata, "Olympus:PictureModeEffect")
        guard !effect.isEmpty, effect != "Standard", effect != "n/a" else { return }
        look.pictureModeEffect = effect
    }

    /// `"High Key; User-Selected"` — two independent components: the tone curve, and whether the
    /// camera overrode it itself. Both defaults drop out, so an auto-gradation frame in an
    /// otherwise untouched mode still reports `"grad auto"`.
    private static func gradation(_ metadata: [String: Any], into look: inout CameraLook) {
        let fields = self.fields(metadata, "Olympus:Gradation")
        guard let curve = fields.first, !curve.isEmpty else { return }

        if curve != "Normal", curve != "n/a" { look.gradation = curve.lowercased() }
        if fields.count >= 2, fields[1] == "Auto-Override" { look.gradationIsAuto = true }
    }

    /// `"Color 0; 0; 29; Strength 0; -4; 3"` — colour position on the ring, its min and max, then
    /// strength with its own min and max. Only fields 0 and 3 are readings.
    ///
    /// `color` is a ring position, not an amount, so `0` must not be suppressed as a default the way
    /// a zeroed hue slider is — see `colorCreatorNames`. Strength is the amount, and its `0` is the
    /// true no-op: at strength 0 nothing is applied whatever the position, so both drop out
    /// together. It is reported as `vivid` because that is what the camera and OM Workspace both
    /// call it on screen; only exiftool's PrintConv says "Strength".
    ///
    /// Strength is bipolar rather than an intensity: -4 is exact monochrome (R=G=B, verified across
    /// five positions and all 36 sectors of the hue wheel), 0 sits at the untouched reference, and
    /// +3 boosts. Negative values behave like Partial Color, keeping hues near the cast and
    /// collapsing the rest toward it.
    ///
    /// `-4` is annotated as mono because the file otherwise gives no hint that the frame is black
    /// and white — the picture mode still reads "Color Creator". The ring position is *not*
    /// suppressed alongside it, even though the output carries no colour: the cast is applied before
    /// the desaturation, so the position still decides which hues render light or dark, the way a
    /// B&W contrast filter does. Measured across the five mono frames, the per-sector luminance
    /// profile moves by up to a third between positions. (Direction only — those frames had
    /// uncontrolled exposure, so the size of the effect is not pinned down.)
    private static func colorCreator(_ metadata: [String: Any], into look: inout CameraLook) {
        let fields = self.fields(metadata, "Olympus:ColorCreatorEffect")
        guard fields.count >= 4,
            let strength = trailingInt(fields[3]), strength != 0,
            let color = trailingInt(fields[0])
        else { return }

        look.colorCreator = CameraLook.ColorCreator(
            position: color, name: colorCreatorName(color), strength: strength)
    }

    /// `MonochromeProfileSettings` is `"Red Filter; 0; 8; Strength 3; 0; 3"` — same min/max-padded
    /// shape as `ColorCreatorEffect`. `MonochromeVignetting` is the Shading Effect wheel and has no
    /// PrintConv at all, so it arrives as a bare number (-5...+5, positive white / negative black,
    /// 0 unshaded). `MonochromeColor` treats both `"(none)"` and `"Normal"` as untoned.
    ///
    /// `MonochromeVignetting`'s name is Olympus's and is narrower than the setting: the colour
    /// profiles carry the same -5...+5 shading slider, and the camera stores it in this same tag.
    /// So `shading` is emitted whatever the picture mode — H1071920 is a Colour Profile 4 frame
    /// reading `shading +1`, which is correct, not a stale monochrome value leaking. (The value is
    /// held per picture mode, not globally: H1071919 reads 0 immediately after a monochrome frame
    /// set it to -2.) That is also why the shading read lives here despite the function's name —
    /// splitting it out would move code without changing a single rendered string.
    ///
    /// Filter choice and strength are stored independently, so a selected filter at strength 0 is
    /// inert and is suppressed. Measured, not assumed: on a fixed-exposure test set the colour-to-
    /// grey weights for No Filter, Blue and Yellow all at strength 0 agree to within 0.4%, while one
    /// strength step moves them by 10% or more (Blue str3 takes the blue weight from 0.12 to 0.76).
    /// The camera also leaves a stale strength behind when the filter is set to None, which is why
    /// the strength alone can't be trusted as the "is a filter applied" signal either.
    private static func monochrome(_ metadata: [String: Any], into look: inout CameraLook) {
        let profile = fields(metadata, "Olympus:MonochromeProfileSettings")
        if profile.count >= 4, profile[0] != "No Filter",
            let filter = profile[0].components(separatedBy: " Filter").first, !filter.isEmpty,
            let strength = trailingInt(profile[3]), strength != 0
        {
            look.monochromeFilter = CameraLook.MonochromeFilter(
                name: filter.lowercased(), strength: strength)
        }

        let grain = text(metadata, "Olympus:FilmGrainEffect")
        if !grain.isEmpty, grain != "Off" { look.grain = grain }

        if let shading = trailingInt(text(metadata, "Olympus:MonochromeVignetting")), shading != 0 {
            look.shading = shading
        }

        let tint = text(metadata, "Olympus:MonochromeColor")
        if !tint.isEmpty, tint != "Normal", tint != "(none)" {
            look.monochromeTint = tint.lowercased()
        }
    }

    /// `"Min -5; Max 5; Yellow 0; Orange 0; ..."` — the leading Min/Max pair is the camera's slider
    /// range, not data, so the 12 hues start at field 2. Named positionally via `hueCodes` rather
    /// than by matching exiftool's hue names, since only the order is being relied on.
    private static func colorProfile(_ metadata: [String: Any], into look: inout CameraLook) {
        let fields = self.fields(metadata, "Olympus:ColorProfileSettings")
        guard fields.count >= 14 else { return }

        look.hueSliders = zip(hueCodes, fields[2..<14])
            .compactMap { code, field in
                guard let value = trailingInt(field), value != 0 else { return nil }
                return CameraLook.Slider(code: code, value: value)
            }
    }

    /// The profile's own contrast/sharpness/saturation, as `"-2 (min -2, max 2)"` — a leading value
    /// with the camera's range in parentheses, not a semicolon list like the tags above.
    ///
    /// These are genuinely dialled per profile, not fixed per mode: the sample set has Monochrome
    /// Profile 4 shot at contrast 0 and again at -2, and Colour Profile 4 at sharpness 0 and again
    /// at +1. `Olympus:ContrastSetting`/`SharpnessSetting`/`CustomSaturation` carry the same numbers
    /// on a wider ±5 scale; the `PictureMode*` tags are read instead because they're scoped to the
    /// picture mode being described.
    private static func contrastSharpnessSaturation(
        _ metadata: [String: Any], into look: inout CameraLook
    ) {
        func reading(_ key: String) -> Int? {
            guard let value = leadingInt(text(metadata, key)), value != 0 else { return nil }
            return value
        }
        look.contrast = reading("Olympus:PictureModeContrast")
        look.sharpness = reading("Olympus:PictureModeSharpness")
        look.saturation = reading("Olympus:PictureModeSaturation")
    }

    /// `"Highlights; 0; -7; 7; Shadows; 0; -7; 7; Midtones; 0; -7; 7; 0; 0; ..."` — four fields per
    /// channel (name, value, min, max), then a run of unused padding this stops before.
    private static func tone(_ metadata: [String: Any], into look: inout CameraLook) {
        let fields = self.fields(metadata, "Olympus:ToneLevel")

        for start in stride(from: 0, to: fields.count - 1, by: 4) {
            guard let code = toneCodes[fields[start]] else { continue }
            guard let value = trailingInt(fields[start + 1]), value != 0 else { continue }
            look.toneLevels.append(CameraLook.Slider(code: code, value: value))
        }
    }

    /// The last whitespace-separated token as an `Int` — pulls `3` out of both `"Strength 3"` and a
    /// bare `"3"`, so a labelled field and an unlabelled one read the same way.
    private static func trailingInt(_ field: String) -> Int? {
        field.split(separator: " ").last.flatMap { Int($0) }
    }

    /// The first whitespace-separated token as an `Int` — pulls `-2` out of `"-2 (min -2, max 2)"`,
    /// where `trailingInt` would trip over the trailing `"2)"`.
    private static func leadingInt(_ field: String) -> Int? {
        field.split(separator: " ").first.flatMap { Int($0) }
    }

    private static func fields(_ metadata: [String: Any], _ key: String) -> [String] {
        text(metadata, key)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A tag with no PrintConv (e.g. `MonochromeVignetting`) arrives as a JSON number rather than a
    /// string, so everything is normalised through `String(describing:)`.
    private static func text(_ metadata: [String: Any], _ key: String) -> String {
        guard let value = metadata[key] else { return "" }
        return String(describing: value).trimmingCharacters(in: .whitespaces)
    }
}
