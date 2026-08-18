import Foundation

/// Groups photo assets into `CaptureSet`s — one set per press of the shutter, where a burst, a
/// bracket, an in-camera composite or a whole interval/timelapse run counts as one press. See
/// docs/SPEC.md §1.
///
/// The timestamp alone cannot do this. The OM-3 writes `DateTimeOriginal` in whole seconds and no
/// `SubSecTimeOriginal`, so a 68-frame burst spans 3 seconds while two deliberate presses can land
/// in the same second: gaps within one capture and gaps between separate captures overlap
/// completely. The camera's own signals (`CaptureSignals`) break the tie where they're available,
/// and where they aren't the gap still does better than the same-second rule this replaced.
public struct CaptureGroupingService {
    /// Frames further apart than this start a new set, unless the camera's shot counter says
    /// otherwise. One second, matching the coarsest timestamp the camera writes.
    public static let gapThreshold: TimeInterval = 1

    public init() {}

    /// One entry per shutter press. `signals` is keyed by asset URL and may be empty (iPad, or any
    /// file whose maker notes didn't read), in which case grouping falls back to the gap alone.
    ///
    /// Assets with no readable capture time each become their own singleton set — there's nothing
    /// to group them by — and those sort after every timestamped set rather than being dropped.
    public func group(_ assets: [PhotoAsset], signals: [URL: CaptureSignals] = [:]) -> [CaptureSet] {
        var frames = Self.frames(from: assets, signals: signals)
        let untimed = assets.filter { $0.capturedAt == nil }
        guard !frames.isEmpty else { return untimed.map { CaptureSet(members: [$0]) } }

        var sets: [CaptureSet] = []
        var previous = frames.removeFirst()
        var run: [Frame] = [previous]
        for frame in frames {
            let boundary = Self.startsNewSet(
                gap: frame.time.timeIntervalSince(previous.time),
                previous: previous.signals,
                next: frame.signals,
                runStart: run[0].signals,
                runLength: run.count)
            previous = frame
            if boundary {
                sets.append(CaptureSet(members: run.flatMap(\.members)))
                run = [frame]
            } else {
                run.append(frame)
            }
        }
        sets.append(CaptureSet(members: run.flatMap(\.members)))
        return sets + untimed.map { CaptureSet(members: [$0]) }
    }

    /// The six checks, in order, deciding whether `next` opens a new capture set after `previous`.
    /// Each was needed by real frames off an OM-3 test card; the order matters as much as the
    /// checks, because the earlier ones are the ones that outrank the clock.
    static func startsNewSet(
        gap: TimeInterval, previous: CaptureSignals, next: CaptureSignals,
        runStart: CaptureSignals, runLength: Int
    ) -> Bool {
        // 1. Interval shooting is decided entirely by its own counter and never by the gap: the
        //    whole point of a timelapse is that its frames are far apart, so a night of star-trail
        //    frames 30 seconds apart is one capture set. An interval frame beside a hand-shot one,
        //    or a counter back at 1, is where one run ended and the next thing began.
        if previous.intervalIndex != nil || next.intervalIndex != nil {
            guard let previousIndex = previous.intervalIndex, let nextIndex = next.intervalIndex
            else { return true }
            return nextIndex <= previousIndex
        }
        // 2. An advancing shot counter is the camera saying "still the same sequence", and it beats
        //    any gap — a wide focus bracket holds the shutter open long enough to put seconds
        //    between frames of one capture (7s on the test card).
        if let previousShot = previous.shotNumber, let nextShot = next.shotNumber,
            nextShot > previousShot
        {
            return false
        }
        // 3. Otherwise the gap decides first.
        if gap > Self.gapThreshold { return true }
        // 4. An in-camera composite belongs with the frames it was built from, and its own source
        //    count is the proof — a composite that followed a run of a different length is a
        //    separate capture that merely happened to land nearby.
        if previous.shotNumber != nil, let sourceFrames = next.stackedFrameCount {
            return sourceFrames != runLength
        }
        // 5. A shot counter that restarted, started or ended is a sequence boundary.
        if previous.shotNumber != nil || next.shotNumber != nil { return true }
        // 6. A render the run already opened with is the bracket starting over. An art bracket
        //    sets no shot counter at all, so two presses of one land in adjacent seconds writing
        //    the same sequence of renders twice; every adjacent pair inside a run differs, and the
        //    repeat of the run's *first* render is the only place the seam shows. With a run of
        //    one this is also the plain case: two singles rendered identically in the same second
        //    are two presses, not one bracket.
        //    Only decisive when the renders are actually known: unknown must never split.
        if let nextRender = next.renderSignature {
            if let firstRender = runStart.renderSignature { return firstRender == nextRender }
            if let previousRender = previous.renderSignature { return previousRender == nextRender }
        }
        return false
    }

    /// A frame is one shutter press's worth of files: a JPEG, its RAW, an unfiltered `.ORI`, and any
    /// derivative developed from the RAW all share a filename stem and must never be split apart by
    /// the checks above.
    private struct Frame {
        let key: String
        let time: Date
        var members: [PhotoAsset]
        var signals: CaptureSignals
    }

    private static func frames(from assets: [PhotoAsset], signals: [URL: CaptureSignals]) -> [Frame] {
        var byKey: [String: [PhotoAsset]] = [:]
        for asset in assets where asset.capturedAt != nil {
            byKey[frameKey(for: asset), default: []].append(asset)
        }
        return byKey.map { key, members in
            // JPEG first, then filename order, so a frame's signals come from the rendered file
            // rather than its RAW — the RAW deliberately stays at the neutral picture mode, which
            // would make every frame of a rendering bracket look identically rendered.
            let ordered = members.sorted { preferenceKey($0) < preferenceKey($1) }
            var merged = CaptureSignals()
            for member in ordered { merged.fillGaps(from: signals[member.url] ?? CaptureSignals()) }
            return Frame(
                key: key,
                time: ordered.compactMap(\.capturedAt).min() ?? .distantPast,
                members: ordered,
                signals: merged)
        }
        .sorted { ($0.time, $0.key) < ($1.time, $1.key) }
    }

    private static func frameKey(for asset: PhotoAsset) -> String {
        (asset.derivedFrom ?? asset.url).deletingPathExtension().lastPathComponent.lowercased()
    }

    private static func preferenceKey(_ asset: PhotoAsset) -> (Int, String) {
        let isJPEG = ["jpg", "jpeg"].contains(asset.url.pathExtension.lowercased())
        return (isJPEG ? 0 : 1, asset.url.lastPathComponent)
    }
}
