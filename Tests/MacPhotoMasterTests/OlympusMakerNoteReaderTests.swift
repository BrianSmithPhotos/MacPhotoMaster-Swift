import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

/// Byte-level tests for the maker-note reader, built on a fixture rather than a card file so they
/// run anywhere. `testMatchesExifToolAcrossACard` is the other half and needs real frames — see its
/// doc comment.
final class OlympusMakerNoteReaderTests: XCTestCase {
    /// One IFD entry's worth of fixture: the payload is the value's actual bytes, and the builder
    /// decides from its length whether it sits inline in the entry or out in the trailing pool,
    /// which is the branch worth exercising rather than stubbing.
    private struct Entry {
        let tag: Int
        let format: Int
        let count: Int
        let payload: [UInt8]
    }

    private func short(_ values: [Int]) -> [UInt8] { values.flatMap(le16) }
    private func long(_ values: [Int]) -> [UInt8] { values.flatMap(le32) }
    private func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
    private func le32(_ value: Int) -> [UInt8] {
        let unsigned = value < 0 ? value + (1 << 32) : value
        return (0..<4).map { UInt8((unsigned >> ($0 * 8)) & 0xFF) }
    }

    /// Serialises one IFD at `start`, measured in the same frame of reference its own offsets will
    /// be read in — which is the whole subtlety this reader had to get right.
    private func ifd(_ entries: [Entry], at start: Int) -> [UInt8] {
        var pool = start + 2 + entries.count * 12 + 4
        var body: [UInt8] = le16(entries.count)
        var values: [UInt8] = []
        for entry in entries {
            body += le16(entry.tag) + le16(entry.format) + le32(entry.count)
            if entry.payload.count <= 4 {
                body += entry.payload + [UInt8](repeating: 0, count: 4 - entry.payload.count)
            } else {
                body += le32(pool)
                values += entry.payload
                pool += entry.payload.count
            }
        }
        return body + le32(0) + values
    }

    /// A maker note whose internal offsets start from the note itself, headed the way an OM System
    /// body heads it, with its `CameraSettings` subdirectory hung off tag 0x2020.
    private func makerNote(cameraSettings: [Entry]) -> [UInt8] {
        let header = Array("OM SYSTEM\0".utf8) + [UInt8](repeating: 0, count: 6)
        let noteIFDStart = 16
        let settingsStart = noteIFDStart + 2 + 12 + 4
        let noteIFD = ifd(
            [Entry(tag: 0x2020, format: 13, count: 1, payload: le32(settingsStart))],
            at: noteIFDStart)
        return header + noteIFD + ifd(cameraSettings, at: settingsStart)
    }

    /// The TIFF block: IFD0 pointing at an ExifIFD, which holds the exposure bias and the note.
    ///
    /// `padding` inflates a filler entry sitting ahead of the note in the value pool, which is how a
    /// note gets pushed past the reader's head-read cap without inventing a fake container.
    private func tiffBlock(note: [UInt8], padding: Int = 0) -> [UInt8] {
        let ifd0Start = 8
        let exifStart = ifd0Start + 2 + 12 + 4
        let ifd0 = ifd(
            [Entry(tag: 0x8769, format: 4, count: 1, payload: le32(exifStart))], at: ifd0Start)
        var entries = [Entry(tag: 0x9204, format: 10, count: 1, payload: le32(-7) + le32(10))]
        if padding > 0 {
            entries.append(
                Entry(
                    tag: 0x9286, format: 7, count: padding,
                    payload: [UInt8](repeating: 0x20, count: padding)))
        }
        entries.append(Entry(tag: 0x927C, format: 7, count: note.count, payload: note))
        return Array("II".utf8) + le16(42) + le32(ifd0Start) + ifd0 + ifd(entries, at: exifStart)
    }

    private func writeTemporaryFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).orf")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The real shape of `ArtFilterEffect`: 20 components, of which only the first four name the
    /// render — long enough that the reader's own per-entry component cap bites before the end,
    /// which is exactly why the signature takes a fixed prefix rather than the whole entry.
    private let artFilterEffect = [6, 1280, 0, 0, 32864, 1280, 0, 0, 32880, 1280, 0, 0]
        + [Int](repeating: 0, count: 8)

    /// Drive mode says shot 3 of a sequence, the stack says eight source frames, the interval
    /// counter is idle, and the render is an art filter over a picture mode at -0.7 EV.
    private var cameraSettings: [Entry] {
        [
            Entry(tag: 0x520, format: 3, count: 2, payload: short([2, 2])),
            Entry(tag: 0x52F, format: 3, count: 20, payload: short(artFilterEffect)),
            Entry(tag: 0x600, format: 3, count: 6, payload: short([5, 3, 1, 0, 0, 7])),
            Entry(tag: 0x605, format: 3, count: 2, payload: short([0, 0])),
            Entry(tag: 0x804, format: 4, count: 2, payload: long([9, 8])),
        ]
    }

    private func jpeg(_ tiff: [UInt8]) -> Data {
        let segment = Array("Exif\0\0".utf8) + tiff
        let length = segment.count + 2
        return Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + segment)
    }

    /// The note sits well past the start of the TIFF block here, so a reader that measured the
    /// note's internal offsets from the TIFF header instead of from the note would land in the
    /// wrong bytes and fail this outright.
    func testReadsEveryGroupingSignalFromAJpegMakerNote() {
        let signals = OlympusMakerNoteReader.signals(in: jpeg(tiffBlock(note: makerNote(cameraSettings: cameraSettings))))

        XCTAssertEqual(signals?.shotNumber, 3)
        XCTAssertNil(signals?.intervalIndex)
        XCTAssertEqual(signals?.stackedFrameCount, 8)
        XCTAssertEqual(signals?.renderSignature, "6 1280 0 0|2 2|-0.7")
    }

    /// A RAW carries the same note in its own TIFF tree with no JPEG segments around it, so the
    /// reader has to find the header in both containers.
    func testReadsTheSameSignalsFromABareTiffContainer() {
        let tiff = tiffBlock(note: makerNote(cameraSettings: cameraSettings))

        let fromRaw = OlympusMakerNoteReader.signals(in: Data(tiff))

        XCTAssertEqual(fromRaw, OlympusMakerNoteReader.signals(in: jpeg(tiff)))
        XCTAssertEqual(fromRaw?.shotNumber, 3)
    }

    /// Mode 6 is HDR2, where the parameter is the HDR setting rather than a source-frame count —
    /// reading it as a count would invent a stack that grouping then tries to match a run against.
    func testHDRParameterIsNotReadAsAFrameCount() {
        let hdr = cameraSettings.map {
            $0.tag == 0x804 ? Entry(tag: 0x804, format: 4, count: 2, payload: long([6, 4])) : $0
        }

        let signals = OlympusMakerNoteReader.signals(in: jpeg(tiffBlock(note: makerNote(cameraSettings: hdr))))

        XCTAssertNil(signals?.stackedFrameCount)
    }

    /// Grainy Film I and II are one filter as far as `ArtFilter` (0x0529) is concerned — it reports
    /// `6 1280` for both — so a bracket holding both writes two frames that tag cannot separate.
    /// The signature reads `ArtFilterEffect` (0x052F) instead, which numbers them apart, and this is
    /// the case that forced the change: shot on the OM-3 test card as D1073877 and D1073878.
    func testFilterVariantsThatShareAnArtFilterValueAreStillDifferentRenders() {
        let grainyFilmII = [19, 4352] + artFilterEffect.dropFirst(2)
        let settings = { (effect: [Int]) in
            self.cameraSettings.map {
                $0.tag == 0x52F
                    ? Entry(tag: 0x52F, format: 3, count: 20, payload: self.short(effect)) : $0
            }
        }

        let one = OlympusMakerNoteReader.signals(in: jpeg(tiffBlock(note: makerNote(cameraSettings: settings(artFilterEffect)))))
        let two = OlympusMakerNoteReader.signals(in: jpeg(tiffBlock(note: makerNote(cameraSettings: settings(grainyFilmII)))))

        XCTAssertEqual(one?.renderSignature, "6 1280 0 0|2 2|-0.7")
        XCTAssertEqual(two?.renderSignature, "19 4352 0 0|2 2|-0.7")
    }

    func testFileWithNoOlympusNoteIsUnknownRatherThanEmpty() {
        var foreign = makerNote(cameraSettings: cameraSettings)
        foreign.replaceSubrange(0..<10, with: Array("Apple iOS\0".utf8))

        XCTAssertNil(OlympusMakerNoteReader.signals(in: jpeg(tiffBlock(note: foreign))))
    }

    /// A card pulled mid-write is a real thing to meet, and it must read as unknown rather than
    /// trap on an offset that runs off the end of the bytes.
    ///
    /// Every length, not a stride: this used to step by 7 and so jumped straight over 12, the one
    /// length that actually trapped — a JPEG ending exactly at its `Exif\0\0` marker, which put the
    /// TIFF header's offset one byte past the end.
    func testTruncatedFileReadsAsUnknownRatherThanTrapping() {
        let whole = jpeg(tiffBlock(note: makerNote(cameraSettings: cameraSettings)))

        for length in 0...whole.count {
            _ = OlympusMakerNoteReader.signals(in: whole.prefix(length))
        }
    }

    func testEmptyDataIsUnknown() {
        XCTAssertNil(OlympusMakerNoteReader.signals(in: Data()))
    }

    /// Reading from a URL takes only the head of the file, so it has to agree with reading the whole
    /// of it — the file path is what the app actually calls.
    func testReadingFromAFileAgreesWithReadingTheWholeBytes() throws {
        let bytes = jpeg(tiffBlock(note: makerNote(cameraSettings: cameraSettings)))

        let fromFile = try OlympusMakerNoteReader.signals(at: writeTemporaryFile(bytes))

        XCTAssertEqual(fromFile, OlympusMakerNoteReader.signals(in: bytes))
        XCTAssertEqual(fromFile?.shotNumber, 3)
    }

    /// A note sitting past the head-read cap must still be found. The head read is an optimisation,
    /// and an optimisation that silently loses the signals would put grouping straight back to the
    /// timestamp gap on exactly the frames it most needs help with.
    func testNoteBeyondTheHeadReadIsStillFoundViaTheWholeFile() throws {
        let bytes = Data(tiffBlock(note: makerNote(cameraSettings: cameraSettings), padding: 300 * 1024))

        let fromFile = try OlympusMakerNoteReader.signals(at: writeTemporaryFile(bytes))

        XCTAssertGreaterThan(bytes.count, 256 * 1024, "fixture must exceed the head cap to test this")
        XCTAssertEqual(fromFile?.shotNumber, 3)
        XCTAssertEqual(fromFile?.stackedFrameCount, 8)
        XCTAssertEqual(fromFile, OlympusMakerNoteReader.signals(in: bytes))
    }

    /// The rule that makes the head read safe: given only part of a file, the reader either answers
    /// exactly as it would with all of it, or says nothing. A partial answer is the dangerous case,
    /// because a truncated `DriveMode` reads as a frame that simply never had a counter.
    func testAPrefixEitherAnswersInFullOrNotAtAll() {
        let whole = jpeg(tiffBlock(note: makerNote(cameraSettings: cameraSettings)))
        let expected = OlympusMakerNoteReader.signals(in: whole)
        XCTAssertNotNil(expected)

        for length in 0..<whole.count {
            let partial = OlympusMakerNoteReader.signals(
                in: whole.prefix(length), requiringCompleteRead: true)
            if let partial {
                XCTAssertEqual(partial, expected, "answered differently from \(length) bytes")
            }
        }
    }

    /// The real proof, and the reason the reader exists: it must agree with `exiftool` tag for tag
    /// on frames a camera actually wrote, including the render signature. Point `MPM_TEST_CARD` at
    /// a card or a folder of frames to run it; skipped when it isn't set, since the fixture above
    /// can only prove the walk, never the format.
    func testMatchesExifToolAcrossACard() async throws {
        let path = ProcessInfo.processInfo.environment["MPM_TEST_CARD"]
        try XCTSkipIf(path == nil, "set MPM_TEST_CARD to a folder of camera frames to run this")
        let files = try FileManager.default
            .contentsOfDirectory(at: URL(fileURLWithPath: path!), includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "orf", "ori"].contains($0.pathExtension.lowercased()) }
        try XCTSkipIf(files.isEmpty, "no camera frames in \(path!)")

        let exifTool = try await ExifToolClient().readGroupingSignals(at: files)

        for file in files {
            XCTAssertEqual(
                OlympusMakerNoteReader.signals(at: file), exifTool[file],
                "disagreed on \(file.lastPathComponent)")
        }
    }
}
