import Foundation

/// Reads the five OM System maker-note tags capture-set grouping needs, by walking the file's own
/// bytes rather than asking `exiftool`. This is the iPad's only route to them: iOS cannot spawn a
/// subprocess, and ImageIO returns no Olympus maker-note dictionary for these files at all —
/// `kCGImagePropertyMakerOlympusDictionary` is absent from both the JPEG and the ORF off a real
/// OM-3 card, even though the note is plainly there in the bytes (see `NativeMetadataReader`'s
/// header for the wider ImageIO scope gap this belongs to).
///
/// Deliberately not a general maker-note decoder. Everything grouping needs lives in one
/// subdirectory, Olympus `CameraSettings` (0x2020), so this walks to exactly that and reads five
/// tags out of it. Anything it cannot make sense of returns `nil`, which grouping already treats
/// as "unknown" and never as a boundary.
///
/// Two format details, both taken from `exiftool`'s `MakerNoteOlympus3` definition rather than
/// guessed, and both places a parser like this normally breaks:
///
/// - The note is headed `OM SYSTEM\0`, not the `OLYMP\0` of older bodies, and its IFD starts 16
///   bytes in.
/// - Offsets *inside* the note are relative to the start of the note itself, not to the TIFF
///   header the rest of the file's offsets are measured from.
public enum OlympusMakerNoteReader {
    /// The grouping signals for one file, or `nil` if it has no readable OM System maker note —
    /// a different make, a JPEG the camera never wrote, or a truncated file.
    public static func signals(at url: URL) -> CaptureSignals? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return signals(in: data)
    }

    /// A whole folder's worth, off the calling actor. Each file is cheap on its own — a mapped read
    /// and a few hundred bytes of walking — but a card holds several hundred frames, and none of
    /// that belongs on the thread drawing the grid.
    public static func signals(at urls: [URL]) async -> [URL: CaptureSignals] {
        await Task.detached(priority: .userInitiated) {
            urls.reduce(into: [URL: CaptureSignals]()) { found, url in found[url] = signals(at: url) }
        }.value
    }

    static func signals(in bytes: Data) -> CaptureSignals? {
        // Every offset below is measured from the start of the file, so a `Data` slice — whose own
        // indices start wherever it was sliced from — has to be rebased before any of it is read.
        let data = bytes.startIndex == 0 ? bytes : Data(bytes)
        guard let tiff = tiffHeaderOffset(in: data) else { return nil }
        let file = TIFFBytes(data: data, isBigEndian: data[tiff] == 0x4D)
        guard let ifd0 = file.uint32(at: tiff + 4) else { return nil }

        // IFD0 -> ExifIFD -> MakerNote, then EXIF's own exposure bias while we are in there: it is
        // part of the render signature and costs nothing extra to read from a walk already made.
        guard let exifPointer = file.entries(at: tiff + ifd0, base: tiff).first(where: { $0.tag == 0x8769 }),
            let exifOffset = file.uint32(at: exifPointer.valueOffset)
        else { return nil }
        let exif = file.entries(at: tiff + exifOffset, base: tiff)
        guard let note = exif.first(where: { $0.tag == 0x927C }) else { return nil }
        let exposure = exif.first { $0.tag == 0x9204 }.flatMap { file.signedRational(at: $0.valueOffset) }

        guard file.matches("OM SYSTEM\0", at: note.valueOffset) else { return nil }
        let noteBase = note.valueOffset
        guard let settings = file.entries(at: noteBase + 16, base: noteBase)
            .first(where: { $0.tag == 0x2020 }),
            let settingsOffset = file.uint32(at: settings.valueOffset)
        else { return nil }

        let camera = file.entries(at: noteBase + settingsOffset, base: noteBase)
        func numbers(_ tag: Int) -> [Int] {
            camera.first { $0.tag == tag }.map { file.numbers(of: $0) } ?? []
        }
        // Rendered as text in the same shape exiftool's `-n` output arrives in, so both platforms
        // build the render signature the same way through `CaptureSignals.grouping`.
        func text(_ tag: Int) -> String {
            numbers(tag).map(String.init).joined(separator: " ")
        }

        return CaptureSignals.grouping(
            driveMode: numbers(0x600),
            intervalCounter: numbers(0x605),
            stackedImage: numbers(0x804),
            render: [text(0x529), text(0x520), exposure.map { String(format: "%g", $0) } ?? ""])
    }

    /// Where the TIFF header starts: byte 0 of an ORF, or inside the Exif APP1 segment of a JPEG.
    /// The two containers are the whole reason this needs finding rather than assuming — the same
    /// maker note sits in the JPEG's APP1 segment and in the ORF's own TIFF tree.
    static func tiffHeaderOffset(in data: Data) -> Int? {
        guard data.count > 8 else { return nil }
        guard data[0] == 0xFF, data[1] == 0xD8 else {
            return data[0] == 0x49 || data[0] == 0x4D ? 0 : nil
        }
        var offset = 2
        while offset + 4 <= data.count, data[offset] == 0xFF {
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            if length < 2 { return nil }
            if data[offset + 1] == 0xE1, offset + 10 <= data.count,
                data[(offset + 4)..<(offset + 10)].elementsEqual(Array("Exif\0\0".utf8))
            {
                return offset + 10
            }
            offset += 2 + length
        }
        return nil
    }
}

/// Bounds-checked reads into one file's bytes, in whichever order its TIFF header declared. Every
/// accessor returns `nil` rather than trapping: these bytes come off a camera card, and a
/// half-written file must degrade to "unknown signals" rather than take the app down.
struct TIFFBytes {
    let data: Data
    let isBigEndian: Bool

    /// One IFD entry, with `valueOffset` already resolved to where the value actually is — inline
    /// in the entry when it fits in four bytes, and out at an offset from `base` when it doesn't.
    struct Entry {
        let tag: Int
        let format: Int
        let count: Int
        let valueOffset: Int
    }

    func uint16(at offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let (a, b) = (Int(data[offset]), Int(data[offset + 1]))
        return isBigEndian ? a << 8 | b : b << 8 | a
    }

    func uint32(at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let b = (0..<4).map { Int(data[offset + $0]) }
        return isBigEndian
            ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
            : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0]
    }

    func int32(at offset: Int) -> Int? {
        uint32(at: offset).map { $0 > Int(Int32.max) ? $0 - (1 << 32) : $0 }
    }

    func signedRational(at offset: Int) -> Double? {
        guard let numerator = int32(at: offset), let denominator = int32(at: offset + 4),
            denominator != 0
        else { return nil }
        return Double(numerator) / Double(denominator)
    }

    func matches(_ ascii: String, at offset: Int) -> Bool {
        let expected = Array(ascii.utf8)
        guard offset >= 0, offset + expected.count <= data.count else { return false }
        return data[offset..<(offset + expected.count)].elementsEqual(expected)
    }

    /// Bytes per component for each TIFF format code, indexed by the code itself. Code 13 is the
    /// IFD pointer Olympus uses for its subdirectories, which is a long by another name.
    private static let componentWidths = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4]

    func entries(at ifd: Int, base: Int) -> [Entry] {
        // An entry count is two bytes, so a wild offset can claim tens of thousands of entries and
        // send this reading megabytes of unrelated file. No Olympus directory comes near 512.
        guard let count = uint16(at: ifd), count > 0, count <= 512,
            ifd + 2 + count * 12 <= data.count
        else { return [] }
        return (0..<count).compactMap { index in
            let entry = ifd + 2 + index * 12
            guard let tag = uint16(at: entry), let format = uint16(at: entry + 2),
                let components = uint32(at: entry + 4), components > 0,
                format < Self.componentWidths.count
            else { return nil }
            let size = Self.componentWidths[format] * components
            let valueOffset = size > 4 ? base + (uint32(at: entry + 8) ?? 0) : entry + 8
            return Entry(tag: tag, format: format, count: components, valueOffset: valueOffset)
        }
    }

    /// An entry's components as integers. Capped because these tags are short by definition — the
    /// longest grouping reads is `DriveMode`'s six — and a corrupt count must not drive a long loop.
    func numbers(of entry: Entry) -> [Int] {
        (0..<min(entry.count, 16)).compactMap { index in
            switch entry.format {
            case 1, 7:
                let byte = entry.valueOffset + index
                return byte >= 0 && byte < data.count ? Int(data[byte]) : nil
            case 3: return uint16(at: entry.valueOffset + index * 2)
            case 4, 13: return uint32(at: entry.valueOffset + index * 4)
            case 9: return int32(at: entry.valueOffset + index * 4)
            default: return nil
            }
        }
    }
}
