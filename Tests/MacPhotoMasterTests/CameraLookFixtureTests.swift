import XCTest

@testable import MacPhotoMasterCore

/// A frozen baseline over the whole measured OM-3 corpus: one frame per distinct maker-note
/// signature, with the `look` and `token` strings the parsers produced when the fixture was
/// recorded.
///
/// `CameraLookParsingTests` covers each rule in isolation with hand-written metadata. This covers
/// the combinations instead — real cameras stack settings in ways a hand-written fixture never
/// thinks to, and every string here came off an actual file rather than being reasoned out. It
/// exists so a behaviour-preserving refactor (splitting `look(from:)` into a `CameraLook` value
/// type, so the visualiser has typed values to render) is provable rather than eyeballed.
///
/// The metadata is exactly what `exiftool -j -G1 -a -s` returned, matching
/// `ExifToolClient.readArguments` — PrintConv text, no `-n`, so the maker-note arrays carry the
/// camera's slider min/max padding.
///
/// A failure here means the rendered strings moved. That is a real result, not a stale fixture:
/// re-record only when the new output is deliberate and has been read line by line. To re-record,
/// point `MPM_RECORD_CAMERA_LOOK_FIXTURE` at the source file and diff before committing:
///
///     MPM_RECORD_CAMERA_LOOK_FIXTURE=Tests/MacPhotoMasterTests/Fixtures/CameraLookFixture.json \
///         swift test --filter CameraLookFixtureTests
///
/// Provenance: OM-3, frames H1071630-H1071915, shot 2026-08-07 to 2026-08-09 to exercise the art
/// filters, the colour and monochrome profiles, the Partial Color and Colour Creator rings, and the
/// plain picture modes. The frame names are kept only so a row can be traced back to the card.
final class CameraLookFixtureTests: XCTestCase {
    private struct Frame {
        let frame: String
        let metadata: [String: Any]
        let token: String
        let look: String
    }

    func testEveryKnownSignatureStillRendersTheSameStrings() throws {
        let frames = try loadFixture()

        // Guards the fixture itself: a resource that silently failed to copy would otherwise let an
        // empty corpus pass as a green test.
        XCTAssertEqual(frames.count, 137, "fixture lost frames")

        if let path = ProcessInfo.processInfo.environment["MPM_RECORD_CAMERA_LOOK_FIXTURE"] {
            try record(frames, to: path)
            return
        }

        for frame in frames {
            XCTAssertEqual(
                ArtFilterTokenParsing.token(from: frame.metadata), frame.token,
                "token changed for \(frame.frame)")
            XCTAssertEqual(
                CameraLookParsing.look(from: frame.metadata), frame.look,
                "look changed for \(frame.frame)")
        }
    }

    /// The corpus is deduplicated on the maker-note fields, so two frames sharing a signature are
    /// one row. Distinct rows may still render alike (a setting the parsers deliberately drop, e.g.
    /// a monochrome filter left at strength 0), so this asserts coverage, not uniqueness.
    func testTheCorpusSpansTheParsersRules() throws {
        let looks = try loadFixture().map(\.look)

        // "shading " is deliberately absent: the Shading Effect A/B was shot as H1071739/H1071740,
        // two frames before this corpus starts, and those files were never dumped in full. That
        // rule is covered by `CameraLookParsingTests`' hand-written `monoProfile3` pair instead.
        for fragment in [
            "Color Creator", "partial ", "bw filter ", "tint ", "grain ",
            "grad ", "contrast ", "sharp ", "sat ", "effect ", "filter str", "fx ",
            "HL", "SH", "Mid", "vivid ",
        ] {
            XCTAssertTrue(
                looks.contains { $0.contains(fragment) }, "corpus no longer exercises \(fragment)")
        }

        // Natural with nothing dialled is the case that must stay silent, so Instructions is never
        // stamped on an ordinary frame.
        XCTAssertTrue(looks.contains(""), "corpus no longer covers the no-write case")
    }

    private func loadFixture() throws -> [Frame] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "CameraLookFixture", withExtension: "json",
                              subdirectory: "Fixtures"),
            "fixture resource missing from the test bundle")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let rows = try XCTUnwrap((json as? [String: Any])?["frames"] as? [[String: Any]])

        return rows.map {
            Frame(
                frame: $0["frame"] as? String ?? "",
                metadata: $0["metadata"] as? [String: Any] ?? [:],
                token: $0["token"] as? String ?? "",
                look: $0["look"] as? String ?? "")
        }
    }

    /// Rewrites the fixture in place with the current output, preserving frame order so the diff
    /// shows only what actually moved.
    private func record(_ frames: [Frame], to path: String) throws {
        let rows: [[String: Any]] = frames.map {
            [
                "frame": $0.frame,
                "metadata": $0.metadata,
                "token": ArtFilterTokenParsing.token(from: $0.metadata),
                "look": CameraLookParsing.look(from: $0.metadata),
            ]
        }
        let body: [String: Any] = [
            "about": "Frozen baseline: one frame per distinct OM-3 maker-note signature. "
                + "See CameraLookFixtureTests.swift.",
            "frames": rows,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: path))
        print("recorded \(rows.count) frames to \(path)")
    }
}
