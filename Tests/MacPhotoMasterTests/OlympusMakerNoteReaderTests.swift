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
    private func tiffBlock(note: [UInt8]) -> [UInt8] {
        let ifd0Start = 8
        let exifStart = ifd0Start + 2 + 12 + 4
        let ifd0 = ifd(
            [Entry(tag: 0x8769, format: 4, count: 1, payload: le32(exifStart))], at: ifd0Start)
        let exif = ifd(
            [
                Entry(tag: 0x9204, format: 10, count: 1, payload: le32(-7) + le32(10)),
                Entry(tag: 0x927C, format: 7, count: note.count, payload: note),
            ], at: exifStart)
        return Array("II".utf8) + le16(42) + le32(ifd0Start) + ifd0 + exif
    }

    /// Drive mode says shot 3 of a sequence, the stack says eight source frames, the interval
    /// counter is idle, and the render is an art filter over a picture mode at -0.7 EV.
    private var cameraSettings: [Entry] {
        [
            Entry(tag: 0x520, format: 3, count: 2, payload: short([2, 2])),
            Entry(tag: 0x529, format: 3, count: 4, payload: short([6, 1280, 0, 0])),
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

    func testFileWithNoOlympusNoteIsUnknownRatherThanEmpty() {
        var foreign = makerNote(cameraSettings: cameraSettings)
        foreign.replaceSubrange(0..<10, with: Array("Apple iOS\0".utf8))

        XCTAssertNil(OlympusMakerNoteReader.signals(in: jpeg(tiffBlock(note: foreign))))
    }

    /// A card pulled mid-write is a real thing to meet, and it must read as unknown rather than
    /// trap on an offset that runs off the end of the bytes.
    func testTruncatedFileReadsAsUnknownRatherThanTrapping() {
        let whole = jpeg(tiffBlock(note: makerNote(cameraSettings: cameraSettings)))

        for length in stride(from: 0, to: whole.count, by: 7) {
            _ = OlympusMakerNoteReader.signals(in: whole.prefix(length))
        }
    }

    func testEmptyDataIsUnknown() {
        XCTAssertNil(OlympusMakerNoteReader.signals(in: Data()))
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
