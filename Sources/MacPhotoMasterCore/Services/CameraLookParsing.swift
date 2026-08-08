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

    /// Returns `""` when nothing non-default was dialled in, so the caller can skip the write
    /// entirely rather than stamping an empty Instructions field.
    public static func look(from metadata: [String: Any]) -> String {
        let mode = ArtFilterTokenParsing.token(from: metadata)
        guard !mode.isEmpty else { return "" }

        var segments = [mode]
        segments.append(contentsOf: colorCreatorSegments(metadata))
        segments.append(contentsOf: monochromeSegments(metadata))
        segments.append(contentsOf: colorProfileSegments(metadata))
        segments.append(contentsOf: toneSegments(metadata))

        return segments.joined(separator: " | ")
    }

    /// `"Color 0; 0; 29; Strength 0; -4; 3"` — colour position on the wheel, its min and max, then
    /// strength with its own min and max. Only fields 0 and 3 are readings.
    private static func colorCreatorSegments(_ metadata: [String: Any]) -> [String] {
        let fields = self.fields(metadata, "Olympus:ColorCreatorEffect")
        guard fields.count >= 4 else { return [] }

        var segments: [String] = []
        if let color = trailingInt(fields[0]), color != 0 { segments.append("color \(color)") }
        if let strength = trailingInt(fields[3]), strength != 0 {
            segments.append("strength \(signed(strength))")
        }
        return segments
    }

    /// `MonochromeProfileSettings` is `"Red Filter; 0; 8; Strength 3; 0; 3"` — same min/max-padded
    /// shape as `ColorCreatorEffect`. `MonochromeVignetting` is the Shading Effect wheel and has no
    /// PrintConv at all, so it arrives as a bare number (-5...+5, positive white / negative black).
    /// `MonochromeColor` treats both `"(none)"` and `"Normal"` as untoned.
    private static func monochromeSegments(_ metadata: [String: Any]) -> [String] {
        var segments: [String] = []

        let profile = fields(metadata, "Olympus:MonochromeProfileSettings")
        if profile.count >= 4, profile[0] != "No Filter",
            let filter = profile[0].components(separatedBy: " Filter").first, !filter.isEmpty,
            let strength = trailingInt(profile[3])
        {
            segments.append("\(filter.lowercased()) filter str\(strength)")
        }

        let grain = text(metadata, "Olympus:FilmGrainEffect")
        if !grain.isEmpty, grain != "Off" { segments.append("grain \(grain)") }

        if let shading = trailingInt(text(metadata, "Olympus:MonochromeVignetting")), shading != 0 {
            segments.append("shading \(signed(shading))")
        }

        let tint = text(metadata, "Olympus:MonochromeColor")
        if !tint.isEmpty, tint != "Normal", tint != "(none)" {
            segments.append("tint \(tint.lowercased())")
        }

        return segments
    }

    /// `"Min -5; Max 5; Yellow 0; Orange 0; ..."` — the leading Min/Max pair is the camera's slider
    /// range, not data, so the 12 hues start at field 2. Named positionally via `hueCodes` rather
    /// than by matching exiftool's hue names, since only the order is being relied on.
    private static func colorProfileSegments(_ metadata: [String: Any]) -> [String] {
        let fields = self.fields(metadata, "Olympus:ColorProfileSettings")
        guard fields.count >= 14 else { return [] }

        let dialled = zip(hueCodes, fields[2..<14])
            .compactMap { code, field -> String? in
                guard let value = trailingInt(field), value != 0 else { return nil }
                return "\(code)\(signed(value))"
            }
        return dialled.isEmpty ? [] : [dialled.joined(separator: " ")]
    }

    /// `"Highlights; 0; -7; 7; Shadows; 0; -7; 7; Midtones; 0; -7; 7; 0; 0; ..."` — four fields per
    /// channel (name, value, min, max), then a run of unused padding this stops before.
    private static func toneSegments(_ metadata: [String: Any]) -> [String] {
        let fields = self.fields(metadata, "Olympus:ToneLevel")

        var dialled: [String] = []
        for start in stride(from: 0, to: fields.count - 1, by: 4) {
            guard let code = toneCodes[fields[start]] else { continue }
            guard let value = trailingInt(fields[start + 1]), value != 0 else { continue }
            dialled.append("\(code)\(signed(value))")
        }
        return dialled.isEmpty ? [] : [dialled.joined(separator: " ")]
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    /// The last whitespace-separated token as an `Int` — pulls `3` out of both `"Strength 3"` and a
    /// bare `"3"`, so a labelled field and an unlabelled one read the same way.
    private static func trailingInt(_ field: String) -> Int? {
        field.split(separator: " ").last.flatMap { Int($0) }
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
