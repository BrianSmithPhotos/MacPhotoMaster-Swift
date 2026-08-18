import Foundation

/// The per-file camera signals `CaptureGroupingService` groups by, beyond the capture timestamp.
///
/// Every field is optional because they come from Olympus/OM System maker notes, which only
/// `exiftool` can read — ImageIO exposes no maker-note dictionary at all, so on iPad these are all
/// `nil` and grouping falls back to the timestamp gap alone. A `nil` never means "no sequence" or
/// "renders differently"; it means "unknown", and the rule is written so unknown never splits.
public struct CaptureSignals: Equatable, Sendable {
    /// The camera's own shot index within a burst or bracket (Olympus `DriveMode`'s second number),
    /// which restarts at 1 for each new sequence. `nil` for a plain single shot.
    public var shotNumber: Int?

    /// The frame's index within an interval-shooting (timelapse) run, counting from 1. `nil` for
    /// anything not shot on the interval timer.
    ///
    /// This is the *only* signal a timelapse leaves: `DriveMode` reads identically for an interval
    /// frame and a hand-shot single (proven on a card shot for the purpose — ten interval frames
    /// bracketed by hand-shot controls, all six `DriveMode` numbers the same), and the gap can't
    /// help because a timelapse interval is by definition longer than any burst.
    ///
    /// It comes from an Olympus CameraSettings tag exiftool does not name, `0x0605`, which sits
    /// right beside `DriveMode` (0x0600) and reads `0 0` off the timer and `<constant> <index>` on
    /// it. Reading it needs exiftool's `-u`, since unnamed tags are suppressed by default.
    public var intervalIndex: Int?

    /// For an in-camera focus-stacked composite, how many source frames it was built from (Olympus
    /// `StackedImage` mode 9's parameter). That count is what proves which preceding bracket the
    /// composite belongs to rather than merely follows.
    public var stackedFrameCount: Int?

    /// How this frame was rendered — art filter, picture mode and exposure compensation combined.
    /// A rendering bracket (one exposure written out several ways) is invisible to `shotNumber`:
    /// the camera marks every frame of it as a plain single shot, so the differing render is the
    /// only thing separating one bracket from several deliberate presses in the same second.
    public var renderSignature: String?

    public init(
        shotNumber: Int? = nil,
        intervalIndex: Int? = nil,
        stackedFrameCount: Int? = nil,
        renderSignature: String? = nil
    ) {
        self.shotNumber = shotNumber
        self.intervalIndex = intervalIndex
        self.stackedFrameCount = stackedFrameCount
        self.renderSignature = renderSignature
    }

    /// Builds the signals from the camera's own numbers, whichever reader recovered them —
    /// `exiftool` on the Mac, `OlympusMakerNoteReader` on the iPad. Shared so the two platforms
    /// cannot drift on what a number means, which is the whole point of the iPad reading the
    /// maker notes at all.
    ///
    /// `render` is the art filter, picture mode and exposure compensation in that order, already
    /// rendered as text; it is joined rather than compared field by field because nothing here
    /// interprets it, it only ever asks whether two frames rendered the same.
    public static func grouping(
        driveMode: [Int], intervalCounter: [Int], stackedImage: [Int], render: [String]
    ) -> CaptureSignals {
        var signals = CaptureSignals()
        // `DriveMode`'s second number is the shot index within the sequence, and 0 means the
        // camera considered this a plain single shot rather than part of one.
        if driveMode.count > 1, driveMode[1] > 0 { signals.shotNumber = driveMode[1] }
        // `0x0605` is (constant, index) while the interval timer is running and `0 0` when it
        // isn't, so a positive index is both the "this is a timelapse frame" flag and its position
        // in the run. Its first number is some descriptor of the run that isn't needed here.
        if intervalCounter.count > 1, intervalCounter[1] > 0 {
            signals.intervalIndex = intervalCounter[1]
        }
        // `StackedImage` is (mode, parameter) and names what one finished frame is, not what it
        // belongs to. Only mode 9, in-camera focus stacking, carries a source frame count — mode
        // 5 and 6 (HDR1/HDR2) reuse the same parameter slot for something that is not a count.
        if stackedImage.count == 2, stackedImage[0] == 9 {
            signals.stackedFrameCount = stackedImage[1]
        }
        // Left nil rather than joined-from-nothing when the camera wrote none of them, so a file
        // with no readable render never looks identical to the next one and splits it off.
        if render.contains(where: { !$0.isEmpty }) {
            signals.renderSignature = render.joined(separator: "|")
        }
        return signals
    }

    /// Fills in whatever this value doesn't know from `other`, used to give a frame one set of
    /// signals when its JPEG and RAW were read separately.
    mutating func fillGaps(from other: CaptureSignals) {
        shotNumber = shotNumber ?? other.shotNumber
        intervalIndex = intervalIndex ?? other.intervalIndex
        stackedFrameCount = stackedFrameCount ?? other.stackedFrameCount
        renderSignature = renderSignature ?? other.renderSignature
    }
}
