import Foundation

/// Groups photo assets captured within the same second into `CaptureSet`s. See docs/SPEC.md §1.
public struct CaptureGroupingService {
    public init() {}

    /// Assets sharing a capture second become one set. Assets with no readable capture time (a
    /// failed metadata read) each become their own singleton set — there's nothing to group them
    /// by — and those sort after every timestamped set rather than being dropped.
    public func group(_ assets: [PhotoAsset]) -> [CaptureSet] {
        var membersBySecond: [Int: [PhotoAsset]] = [:]
        var untimed: [PhotoAsset] = []

        for asset in assets {
            guard let capturedAt = asset.capturedAt else {
                untimed.append(asset)
                continue
            }
            let second = Int(capturedAt.timeIntervalSince1970.rounded())
            membersBySecond[second, default: []].append(asset)
        }

        let timedSets = membersBySecond.keys.sorted().map { CaptureSet(members: membersBySecond[$0]!) }
        let untimedSets = untimed.map { CaptureSet(members: [$0]) }
        return timedSets + untimedSets
    }
}
