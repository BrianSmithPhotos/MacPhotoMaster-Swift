import XCTest

@testable import MacPhotoMaster
@testable import MacPhotoMasterCore

final class CaptureGroupingServiceTests: XCTestCase {
    private let service = CaptureGroupingService()
    private let base = Date(timeIntervalSince1970: 1_000)

    private func asset(_ name: String, capturedAt: Date?) -> PhotoAsset {
        var asset = PhotoAsset(id: URL(fileURLWithPath: "/tmp/\(name)"))
        asset.capturedAt = capturedAt
        return asset
    }

    private func stems(_ sets: [CaptureSet]) -> [[String]] {
        sets.map { $0.members.map { $0.url.lastPathComponent } }
    }

    // MARK: - Frames

    func testRawAndJpegOfOneFrameStayTogether() {
        let jpeg = asset("A.jpg", capturedAt: base)
        let raw = asset("A.orf", capturedAt: base.addingTimeInterval(0.4))

        let sets = service.group([jpeg, raw])

        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(Set(sets[0].members.map(\.id)), Set([jpeg.id, raw.id]))
    }

    /// A derivative is keyed by the RAW it came from, not by its own staging filename, so
    /// developing a RAW must not add a second set beside the original.
    func testDerivedJpegJoinsItsOriginalsFrame() {
        var derived = asset("2048_A.jpg", capturedAt: base)
        derived.derivedFrom = URL(fileURLWithPath: "/tmp/A.orf")

        let sets = service.group([asset("A.orf", capturedAt: base), derived])

        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].members.count, 2)
    }

    func testAssetsWithoutCaptureTimeEachBecomeTheirOwnSet() {
        let sets = service.group([asset("A.jpg", capturedAt: nil), asset("B.jpg", capturedAt: nil)])

        XCTAssertEqual(sets.count, 2)
    }

    func testUntimedSetsSortAfterAllTimedSets() {
        let untimed = asset("B.jpg", capturedAt: nil)

        let sets = service.group([untimed, asset("A.jpg", capturedAt: base)])

        XCTAssertEqual(sets.last?.members.first?.id, untimed.id)
    }

    func testSetsAreOrderedChronologicallyRegardlessOfInputOrder() {
        let later = asset("B.jpg", capturedAt: base.addingTimeInterval(30))
        let earlier = asset("A.jpg", capturedAt: base)

        let sets = service.group([later, earlier])

        XCTAssertEqual(sets.first?.members.first?.id, earlier.id)
        XCTAssertEqual(sets.last?.members.first?.id, later.id)
    }

    // MARK: - The gap, with no camera signals (what the iPad build sees)

    func testFramesWithinTheThresholdGroupOnTheGapAlone() {
        let sets = service.group([
            asset("A.jpg", capturedAt: base),
            asset("B.jpg", capturedAt: base.addingTimeInterval(1)),
        ])

        XCTAssertEqual(stems(sets), [["A.jpg", "B.jpg"]])
    }

    func testFramesBeyondTheThresholdSplit() {
        let sets = service.group([
            asset("A.jpg", capturedAt: base),
            asset("B.jpg", capturedAt: base.addingTimeInterval(2)),
        ])

        XCTAssertEqual(stems(sets), [["A.jpg"], ["B.jpg"]])
    }

    // MARK: - The six checks

    /// Check 1, and the whole point of it: a timelapse's frames are far apart by definition, so the
    /// gap must not get a vote. 150 star-trail frames 30 seconds apart are one capture.
    func testIntervalRunIsOneCaptureHoweverFarApartItsFramesAre() {
        let frames = (1...5).map { asset("A\($0).jpg", capturedAt: base.addingTimeInterval(Double($0) * 30)) }
        let signals = Dictionary(
            uniqueKeysWithValues: frames.enumerated().map {
                ($0.element.url, CaptureSignals(intervalIndex: $0.offset + 1))
            })

        let sets = service.group(frames, signals: signals)

        XCTAssertEqual(stems(sets), [["A1.jpg", "A2.jpg", "A3.jpg", "A4.jpg", "A5.jpg"]])
    }

    func testASecondIntervalRunStartsWhereItsCounterRestarts() {
        let frames = (1...4).map { asset("A\($0).jpg", capturedAt: base.addingTimeInterval(Double($0) * 30)) }
        let indices = [1, 2, 1, 2]
        let signals = Dictionary(
            uniqueKeysWithValues: zip(frames, indices).map {
                ($0.url, CaptureSignals(intervalIndex: $1))
            })

        let sets = service.group(frames, signals: signals)

        XCTAssertEqual(stems(sets), [["A1.jpg", "A2.jpg"], ["A3.jpg", "A4.jpg"]])
    }

    /// A hand-shot frame taken between interval frames is its own capture, not part of the run —
    /// the camera stamps the counter only on frames the timer fired.
    func testHandShotFrameBesideAnIntervalRunIsItsOwnCapture() {
        let intervalFrame = asset("A.jpg", capturedAt: base)
        let handShot = asset("B.jpg", capturedAt: base.addingTimeInterval(0.5))

        let sets = service.group(
            [intervalFrame, handShot], signals: [intervalFrame.url: CaptureSignals(intervalIndex: 1)])

        XCTAssertEqual(stems(sets), [["A.jpg"], ["B.jpg"]])
    }

    /// Check 2: a focus bracket of long exposures puts seconds between frames the camera considers
    /// one sequence, and the shot counter has to outrank the gap for those to stay together.
    func testAdvancingShotNumberHoldsASequenceTogetherAcrossALongGap() {
        let first = asset("A.jpg", capturedAt: base)
        let second = asset("B.jpg", capturedAt: base.addingTimeInterval(7))

        let sets = service.group(
            [first, second],
            signals: [
                first.url: CaptureSignals(shotNumber: 1),
                second.url: CaptureSignals(shotNumber: 2),
            ])

        XCTAssertEqual(stems(sets), [["A.jpg", "B.jpg"]])
    }

    /// Check 4: the composite's own source count is what proves it belongs to the bracket in front
    /// of it, rather than merely following one.
    func testFocusStackedCompositeJoinsTheBracketItWasBuiltFrom() {
        let frames = (1...3).map { asset("A\($0).jpg", capturedAt: base.addingTimeInterval(Double($0))) }
        let composite = asset("A4.jpg", capturedAt: base.addingTimeInterval(4))
        var signals = Dictionary(
            uniqueKeysWithValues: frames.enumerated().map {
                ($0.element.url, CaptureSignals(shotNumber: $0.offset + 1))
            })
        signals[composite.url] = CaptureSignals(stackedFrameCount: 3)

        let sets = service.group(frames + [composite], signals: signals)

        XCTAssertEqual(stems(sets), [["A1.jpg", "A2.jpg", "A3.jpg", "A4.jpg"]])
    }

    func testCompositeOfADifferentLengthIsItsOwnCapture() {
        let frames = (1...3).map { asset("A\($0).jpg", capturedAt: base.addingTimeInterval(Double($0))) }
        let composite = asset("A4.jpg", capturedAt: base.addingTimeInterval(4))
        var signals = Dictionary(
            uniqueKeysWithValues: frames.enumerated().map {
                ($0.element.url, CaptureSignals(shotNumber: $0.offset + 1))
            })
        signals[composite.url] = CaptureSignals(stackedFrameCount: 15)

        let sets = service.group(frames + [composite], signals: signals)

        XCTAssertEqual(stems(sets), [["A1.jpg", "A2.jpg", "A3.jpg"], ["A4.jpg"]])
    }

    /// Check 5: two bursts back to back land within the threshold of each other, and only the
    /// counter restarting says where one ended.
    func testRestartedShotNumberSplitsTwoBurstsInTheSameSecond() {
        let frames = (1...4).map { asset("A\($0).jpg", capturedAt: base) }
        let counters = [1, 2, 1, 2]
        let signals = Dictionary(
            uniqueKeysWithValues: zip(frames, counters).map { ($0.url, CaptureSignals(shotNumber: $1)) })

        let sets = service.group(frames, signals: signals)

        XCTAssertEqual(stems(sets), [["A1.jpg", "A2.jpg"], ["A3.jpg", "A4.jpg"]])
    }

    func testASingleShotNextToASequenceIsItsOwnCapture() {
        let single = asset("A.jpg", capturedAt: base)
        let sequenced = asset("B.jpg", capturedAt: base)

        let sets = service.group(
            [single, sequenced], signals: [sequenced.url: CaptureSignals(shotNumber: 1)])

        XCTAssertEqual(stems(sets), [["A.jpg"], ["B.jpg"]])
    }

    /// Check 6: a rendering bracket is invisible to the counter — the camera calls every frame of
    /// it a plain single shot — so the differing render is all that holds it together.
    func testDifferentlyRenderedSinglesInOneSecondAreOneRenderingBracket() {
        let frames = (1...3).map { asset("A\($0).jpg", capturedAt: base) }
        let signals = Dictionary(
            uniqueKeysWithValues: frames.enumerated().map {
                ($0.element.url, CaptureSignals(renderSignature: "filter\($0.offset)"))
            })

        let sets = service.group(frames, signals: signals)

        XCTAssertEqual(stems(sets), [["A1.jpg", "A2.jpg", "A3.jpg"]])
    }

    func testIdenticallyRenderedSinglesInOneSecondAreSeparateCaptures() {
        let first = asset("A.jpg", capturedAt: base)
        let second = asset("B.jpg", capturedAt: base)
        let render = CaptureSignals(renderSignature: "same")

        let sets = service.group([first, second], signals: [first.url: render, second.url: render])

        XCTAssertEqual(stems(sets), [["A.jpg"], ["B.jpg"]])
    }

    /// Check 6: an art bracket sets no shot counter, so two presses of one land a second apart and
    /// every adjacent pair of renders differs across the seam — including the pair that straddles
    /// it. The second run repeats the first run's renders in the same order, so its opening render
    /// matching the run's opening render is the only marker of the boundary. Shape taken from a
    /// real two-press ART BKT run on the test card (H1073569-H1073584), with the render strings
    /// left as placeholders: the rule compares whole signatures and never inspects a filter.
    func testRepeatedRenderSequenceSplitsTwoArtBracketRuns() {
        let renders = ["natural", "pop", "grainy", "diorama", "cross", "dramatic", "profile3", "profile1"]
        var assets: [PhotoAsset] = []
        var signals: [URL: CaptureSignals] = [:]
        for (run, second) in [(0, 0.0), (1, 1.0)] {
            for (index, render) in renders.enumerated() {
                let frame = asset("R\(run)_\(index).jpg", capturedAt: base.addingTimeInterval(second))
                assets.append(frame)
                signals[frame.url] = CaptureSignals(renderSignature: render)
            }
        }

        let sets = service.group(assets, signals: signals)

        XCTAssertEqual(sets.count, 2)
        XCTAssertEqual(sets.map { $0.members.count }, [8, 8])
    }

    /// A RAW records the neutral picture mode whatever the JPEG beside it was rendered as, so a
    /// frame has to take its render from the JPEG or every bracket would look identically rendered.
    func testFrameTakesItsRenderFromTheJpegNotTheRaw() {
        let jpegs = (1...2).map { asset("A\($0).jpg", capturedAt: base) }
        let raws = (1...2).map { asset("A\($0).orf", capturedAt: base) }
        var signals: [URL: CaptureSignals] = [:]
        for (index, jpeg) in jpegs.enumerated() {
            signals[jpeg.url] = CaptureSignals(renderSignature: "filter\(index)")
        }
        for raw in raws { signals[raw.url] = CaptureSignals(renderSignature: "neutral") }

        let sets = service.group(jpegs + raws, signals: signals)

        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].members.count, 4)
    }
}
