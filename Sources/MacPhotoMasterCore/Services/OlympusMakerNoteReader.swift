import Foundation
import os

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
    /// How much of a file to read before falling back to the whole thing. Everything this reader
    /// walks ends 12,068 bytes into a JPEG and 12,608 into a RAW, measured across all 373 frames of
    /// a camera-original card rather than the exiftool-rewritten library files an earlier size was
    /// taken from. Five times that, so the margin is wide — and undersizing it only costs a second
    /// read, never an answer.
    private static let headLength = 64 * 1024

    /// The grouping signals for one file, or `nil` if it has no readable OM System maker note —
    /// a different make, a JPEG the camera never wrote, or a truncated file.
    ///
    /// Reads the head of the file rather than the whole of it. Mapping the whole file is free on a
    /// mounted card, where only the pages actually touched are ever paged in, and ruinous through
    /// iPadOS's file provider, where a card in a tethered camera cannot be mapped at all and every
    /// byte crosses the cable: the 373-frame test card took 94 seconds read whole and 0.3 seconds
    /// read this way, against 4.2 seconds for the ImageIO pass beside it, which reads incrementally.
    /// The whole-file read stays as the fallback for anything the head didn't cover.
    public static func signals(at url: URL) -> CaptureSignals? {
        read(at: url).signals
    }

    /// The read itself, reporting which path answered. The fallback costs a whole camera-original
    /// RAW — seventeen megabytes and up — against the head's sixty-four kilobytes, so how often it
    /// fires is the difference between a folder opening at once and taking a minute. It is counted
    /// rather than assumed because assuming it got this wrong once already.
    static func read(at url: URL) -> (signals: CaptureSignals?, usedWholeFile: Bool) {
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: headLength),
                let signals = signals(in: head, requiringCompleteRead: true)
            {
                return (signals, false)
            }
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (nil, false) }
        return (signals(in: data), true)
    }

    /// Where the pass actually spends its time. Two rounds of reasoning about it from the Mac each
    /// predicted a speedup the iPad did not deliver, so the device reports rather than the reasoning
    /// predicting: how long the pass took, and how many files needed the expensive whole-file read.
    private static let logger = Logger(subsystem: "MacPhotoMaster", category: "MakerNote")

    /// How many files to have open at once. Sized like `PhotoAssetLoader`'s fan-out for consistency,
    /// though the reason differs: that pass is CPU-bound on ImageIO parsing, while this one spends
    /// nearly all its time waiting on a file provider to hand over the first page.
    private static let concurrentReads = ProcessInfo.processInfo.activeProcessorCount

    /// A whole folder's worth, off the calling actor, several at a time. Each file is cheap once
    /// open — a bounded read and a few hundred bytes of walking — but *opening* it through iPadOS's
    /// file provider is a round trip, and a card holds several hundred frames. Read one after
    /// another, that latency is paid end to end: on the test card, cutting the bytes read per file
    /// by a factor of sixty only halved the wall clock, because the wait was never about bytes.
    /// None of it belongs on the thread drawing the grid either, hence the detached task.
    public static func signals(at urls: [URL]) async -> [URL: CaptureSignals] {
        await Task.detached(priority: .userInitiated) {
            var found: [URL: CaptureSignals] = [:]
            var next = 0
            var wholeFileReads = 0
            let startedAt = Date()

            await withTaskGroup(of: (URL, CaptureSignals?, Bool).self) { group in
                func startNextReadIfAny() {
                    guard next < urls.count else { return }
                    let url = urls[next]
                    next += 1
                    group.addTask {
                        let read = read(at: url)
                        return (url, read.signals, read.usedWholeFile)
                    }
                }

                for _ in 0..<min(concurrentReads, urls.count) { startNextReadIfAny() }
                while let (url, signals, usedWholeFile) = await group.next() {
                    // Assigning nil removes the key, which is what an unreadable file should leave
                    // behind: absent, so grouping treats it as unknown rather than as a boundary.
                    found[url] = signals
                    if usedWholeFile { wholeFileReads += 1 }
                    startNextReadIfAny()
                }
            }
            logger.log(
                """
                Maker-note read: \(found.count) of \(urls.count) files in \
                \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 1))s, \
                \(wholeFileReads) needed the whole file
                """)
            return found
        }.value
    }

    /// - Parameter requiringCompleteRead: reject bytes that stop short of everything this reads,
    ///   rather than answering from what happens to be present. Only a prefix read needs it: a short
    ///   answer and a whole one are both non-`nil`, and grouping cannot tell them apart — it would
    ///   take a truncated `DriveMode` for a frame that simply has no counter, which is the
    ///   misgrouping this whole reader exists to prevent.
    static func signals(in bytes: Data, requiringCompleteRead: Bool = false) -> CaptureSignals? {
        // Every offset below is measured from the start of the file, so a `Data` slice — whose own
        // indices start wherever it was sliced from — has to be rebased before any of it is read.
        let data = bytes.startIndex == 0 ? bytes : Data(bytes)
        // The header itself has to be there, not merely pointed at: a JPEG cut off right after its
        // `Exif\0\0` marker yields an offset one past the last byte, and reading the byte-order mark
        // at it would trap where every other read here degrades to nil.
        guard let tiff = tiffHeaderOffset(in: data), tiff + 8 <= data.count else { return nil }
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
        // Where the bytes this reader touches run out to, accumulated as they are read so the
        // completeness check below is over exactly what was needed and nothing else.
        var tagsEnd = 0
        func numbers(_ tag: Int) -> [Int] {
            guard let entry = camera.first(where: { $0.tag == tag }) else { return [] }
            tagsEnd = max(tagsEnd, file.end(of: entry, components: 16))
            return file.numbers(of: entry)
        }
        // Rendered as text in the same shape exiftool's `-n` output arrives in, so both platforms
        // build the render signature the same way through `CaptureSignals.grouping`.
        func text(_ tag: Int) -> String {
            numbers(tag).map(String.init).joined(separator: " ")
        }

        let signals = CaptureSignals.grouping(
            driveMode: numbers(0x600),
            intervalCounter: numbers(0x605),
            stackedImage: numbers(0x804),
            render: [
                CaptureSignals.artFilterEffect(numbers(0x52F)), text(0x520),
                exposure.map { String(format: "%g", $0) } ?? "",
            ])

        // What a prefix has to have held. Not the whole maker note: on a camera original that note
        // is 1.8MB, nearly all of it an embedded preview this never looks at, and demanding all of
        // it sent every RAW on the card down the whole-file path — 170 of 373 files, and ninety of
        // the ninety-four seconds a folder took to open on the iPad. What must be there is what was
        // actually walked, which the reads above have just tallied. An empty CameraSettings means a
        // truncated one rather than a bare one: `entries` returns nothing at all when the entry
        // array runs off the end, and no OM System frame has none.
        if requiringCompleteRead {
            let wholeBias = exposure != nil || !exif.contains { $0.tag == 0x9204 }
            guard !camera.isEmpty, tagsEnd <= data.count, wholeBias else { return nil }
        }
        return signals
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

    /// The byte just past an entry's first `components` values — how far a prefix read has to reach
    /// for `numbers(of:)` to answer in full rather than thinly, given it reads no more than that
    /// many.
    func end(of entry: Entry, components: Int) -> Int {
        entry.valueOffset + Self.componentWidths[entry.format] * min(entry.count, components)
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
