import Foundation

/// One burst of `DiscoveredCaptureFile`s the Classify step shows as a SINGLE
/// row -- the owner's own words: "csoportosítani is kell ezeket a képeket,
/// amik egymás utána készültek interval-ban, azok egyértelműen majd egy
/// kategóriába fognak tartozni" ("these images need to be grouped, the ones
/// shot back-to-back in an interval -- those will clearly belong to one
/// category"). 2954 files collapse to a handful of these; the wizard assigns
/// a role to the GROUP, never file-by-file, unless a user expands one to
/// override or exclude an individual file.
public struct CaptureFileGroup: Equatable, Sendable, Identifiable {
    /// The first file's own path -- stable across re-grouping runs as long
    /// as that file stays first (grouping is deterministic and re-derives
    /// from the same sorted `discovered` list every time, so this never
    /// drifts under the same input).
    public var id: String { files.first?.id ?? "" }

    /// Every file in this burst, sorted by `captureInstant` (ties broken by
    /// `relativeSourcePath`) -- the exact order `CaptureBurstGrouper.group`
    /// assembled them in.
    public let files: [DiscoveredCaptureFile]

    public init(files: [DiscoveredCaptureFile]) {
        self.files = files
    }

    public var fileCount: Int { files.count }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    public var fileIDs: Set<String> { Set(files.map(\.id)) }

    /// The earliest/latest capture instant in the group -- `nil` only for an
    /// empty group, which `CaptureBurstGrouper.group` never produces.
    public var firstCaptureInstant: Date? { files.map(\.captureInstant).min() }
    public var lastCaptureInstant: Date? { files.map(\.captureInstant).max() }

    /// The shared extension when every file in the group has the same one
    /// (the overwhelmingly common case -- a burst is one shooting run on one
    /// camera), `nil` when a group somehow mixes kinds (e.g. a `.cr3` light
    /// and a `.fits` dark landed in the same interval on a dual-camera rig).
    public var commonExtension: String? {
        let extensions = Set(files.map(\.ext))
        return extensions.count == 1 ? extensions.first : nil
    }

    /// A representative file for the group's thumbnail -- the MIDDLE file by
    /// capture order, not the first: a burst's first frame is sometimes a
    /// framing/focus throwaway, the middle one is the least likely to be an
    /// outlier. `nil` only for an empty group.
    public var representativeFile: DiscoveredCaptureFile? {
        guard !files.isEmpty else { return nil }
        return files[files.count / 2]
    }

    /// The FITS `IMAGETYP`-derived role every file in the group agrees on --
    /// applied group-wise, per the brief ("FITS files keep their existing
    /// IMAGETYP proposal ... now applied group-wise: if all FITS in a group
    /// agree, the group gets the proposal"). `nil` when the group is empty,
    /// contains any file with no proposed role (including every `.cr3`,
    /// which never has one), or contains files that disagree -- never a
    /// majority vote, since a silent guess for the minority is exactly what
    /// the owner's brief prohibits.
    public var agreedProposedRole: FrameRole? {
        guard let first = files.first?.proposedRole else { return nil }
        return files.allSatisfy { $0.proposedRole == first } ? first : nil
    }

    /// The group's own representative Exif summary for its CR3 files --
    /// `nil` when the group has no CR3/raw files with any Exif at all (a
    /// pure-FITS group, or a raw group ImageIO couldn't read). Built from
    /// whichever files in the group actually carried a value; a group is
    /// never penalized for one file with unreadable Exif sitting next to
    /// nine with good data.
    public var exposureSummary: CaptureGroupExposureSummary? {
        CaptureGroupExposureSummary(files: files)
    }
}

/// The median exposure/most-common ISO and aperture across one group's
/// files -- what a photographer actually reads to tell "a run of 0.0002s
/// bias frames" from "a run of 300s lights". Median (not mean) for exposure
/// so one outlier reading (a corrupt Exif tag ImageIO mis-parses) can't drag
/// the group's headline number away from what every other file agrees on.
public struct CaptureGroupExposureSummary: Equatable, Sendable {
    public let medianExposureSeconds: Double?
    public let mostCommonISO: Int?
    public let mostCommonApertureFNumber: Double?

    /// `nil` when NONE of `files` carried any Exif value at all -- there is
    /// nothing honest to summarize.
    public init?(files: [DiscoveredCaptureFile]) {
        let exposures = files.compactMap(\.exposureSeconds)
        let isos = files.compactMap(\.iso)
        let apertures = files.compactMap(\.apertureFNumber)
        guard !exposures.isEmpty || !isos.isEmpty || !apertures.isEmpty else { return nil }

        medianExposureSeconds = Self.median(exposures)
        mostCommonISO = Self.mostCommon(isos)
        mostCommonApertureFNumber = Self.mostCommon(apertures)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func mostCommon<T: Hashable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        var counts: [T: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        // Ties broken by first-seen order (`max(by:)` keeps the FIRST
        // maximal element it visits) rather than by hash order, so the
        // result is deterministic across runs for the same input.
        var best: (value: T, count: Int, index: Int)?
        for (index, value) in values.enumerated() {
            let count = counts[value] ?? 0
            if best == nil || count > best!.count {
                best = (value, count, index)
            }
        }
        return best?.value
    }
}

/// Splits a source card's discovered files into shooting bursts by capture
/// time -- the owner's own diagnosis: "csoportosítani is kell ezeket a
/// képeket, amik egymás utána készültek interval-ban" (files shot
/// back-to-back in an interval group naturally). An astro session is exactly
/// that shape: N lights at a fixed exposure back-to-back, then a flat run,
/// then darks -- each run's own cadence is roughly `exposure + write/readout
/// overhead`, steady within the run and then a large jump at the boundary
/// (repositioning the scope, swapping to a flat panel, walking away to start
/// darks).
///
/// THE RULE: sort every file by `captureInstant`, then walk the sorted list
/// splitting into a new group whenever the gap to the PREVIOUS file exceeds
///
///     max(gapMultiplier × runningMedianGapSoFar, minimumGapFloorSeconds)
///
/// `runningMedianGapSoFar` is the median of every consecutive-file gap
/// already accepted into the CURRENT group (empty at the very first pair,
/// where the rule falls back to the floor alone) -- this adapts to whatever
/// cadence a run actually used (2s biases, 45s flats, 300s lights) instead
/// of assuming one. `gapMultiplier` (4×) tolerates real jitter -- a dropped
/// frame, a slow SD card write, a brief cloud pause -- without mistaking it
/// for a session boundary. `minimumGapFloorSeconds` (15 minutes) is the
/// deliberately generous floor the brief calls for: a run whose own median
/// gap is tiny (bias frames a few seconds apart) still tolerates any single
/// gap up to 15 minutes before splitting, and a slow 300s-per-light cadence
/// (exactly the case the brief names as one that "must not split") sits
/// comfortably under the floor on its own, before the multiplier even
/// enters into it.
///
/// This is intentionally simple and PURELY time-based -- it does not look at
/// exposure length, role, or file extension when deciding where to split.
/// Two different exposure lengths shot within one interval (e.g. a
/// mis-triggered frame in the middle of a light run) land in the SAME group;
/// the Classify step's per-file expand/override handles that, rather than
/// this rule trying to be clever about content it hasn't been told to read
/// yet.
public enum CaptureBurstGrouper {
    /// How many times the running median intra-group gap a single gap may
    /// be before it counts as a session boundary.
    public static let gapMultiplier: Double = 4.0
    /// The floor below which a gap NEVER splits a group, regardless of the
    /// running median -- generous on purpose (see this type's own doc
    /// comment) so a steady 300s light cadence is never split.
    public static let minimumGapFloorSeconds: TimeInterval = 900

    /// Groups `files` into bursts. `files` need not be pre-sorted -- this
    /// sorts its own copy first, so the order the scanner (or a test)
    /// supplies them in never matters. An empty input yields an empty
    /// output; a single file yields exactly one single-file group.
    public static func group(_ files: [DiscoveredCaptureFile]) -> [CaptureFileGroup] {
        guard !files.isEmpty else { return [] }
        let sorted = files.sorted { lhs, rhs in
            if lhs.captureInstant != rhs.captureInstant {
                return lhs.captureInstant < rhs.captureInstant
            }
            return lhs.relativeSourcePath < rhs.relativeSourcePath
        }

        var groups: [[DiscoveredCaptureFile]] = []
        var current: [DiscoveredCaptureFile] = [sorted[0]]
        var acceptedGaps: [TimeInterval] = []

        for file in sorted.dropFirst() {
            let previous = current[current.count - 1]
            let gap = file.captureInstant.timeIntervalSince(previous.captureInstant)
            let threshold = max(gapMultiplier * median(acceptedGaps), minimumGapFloorSeconds)
            if gap > threshold {
                groups.append(current)
                current = [file]
                acceptedGaps = []
            } else {
                acceptedGaps.append(gap)
                current.append(file)
            }
        }
        groups.append(current)
        return groups.map(CaptureFileGroup.init(files:))
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// A suggested role derived PURELY from a group's own median exposure time --
/// never applied automatically, always shown as a suggestion the user
/// confirms (the brief: "always displayed as a suggestion the user confirms,
/// never silently applied"). Only fires in the two exposure ranges where
/// exposure length alone is actually informative:
///
/// - Below `biasMaxSeconds` (10ms): a sensor-readout-only exposure -- no real
///   camera takes a meaningful light/dark/flat at this length, only a bias.
/// - Between `biasMaxSeconds` and `flatMaxSeconds` (10ms-5s): the typical
///   flat-panel/sky-flat range -- short enough that a light or dark at this
///   length would be unusual (though not impossible for a very bright
///   target), so this is a hint, not a certainty.
///
/// Deliberately silent (`nil`) at longer exposures: the brief itself names
/// the reason -- "the difference between dark and light at same exposure is
/// content", which no amount of exposure-time math can resolve. That case is
/// what the group's thumbnail is for, not this heuristic.
public enum CaptureExposureRoleHint {
    public static let biasMaxSeconds: Double = 0.01
    public static let flatMaxSeconds: Double = 5.0

    /// `nil` when `medianExposureSeconds` is `nil` or falls outside either
    /// named range -- "no hint" is always a valid, honest answer.
    public static func suggest(medianExposureSeconds: Double?) -> FrameRole? {
        guard let seconds = medianExposureSeconds, seconds >= 0 else { return nil }
        if seconds < biasMaxSeconds { return .bias }
        if seconds < flatMaxSeconds { return .flat }
        return nil
    }
}
