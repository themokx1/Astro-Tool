import Foundation

/// Canonicalizes ASI-Air-style plate-solve `FOCALLEN` jitter -- e.g. one
/// physical rig writing 255/256/261/262 mm across different nights as its
/// plate-solve refines the focal length -- into ONE stable value, without
/// merging genuinely different optics (a 100 mm lens must stay distinct from
/// a 135 mm one).
///
/// **The rule** (per camera): round every raw mm value to the nearest 5.
/// Then single-link merge ADJACENT buckets that actually occur in the data
/// (an empty gap between two occupied buckets never bridges them) whenever
/// their centers differ by <= 2% relative. 2% is not arbitrary -- it is
/// exactly the gap between the 255 mm and 260 mm buckets (`5/255 ≈ 1.96%`),
/// and 255/256/261/262 mm are the four raw values the W7-C audit verified
/// belong to one physical ASI2600MC Pro rig.
///
/// **Justification against the owner's real library** (`index.sqlite`,
/// ZWO ASI2600MC Pro): the camera's FOCALLEN column holds 238 distinct raw
/// values spanning 101.8-387 mm, almost all of them plate-solve jitter
/// around a handful of true configurations. Rounding to the nearest 5 mm
/// alone still leaves 10 buckets (100, 135, 180, 255, 260, 290, 295, 300,
/// 305, 385 mm); this rule's extra "merge adjacent occupied buckets within
/// 2%" step collapses that down to the real 6: **100, 135, 180, ~257.5
/// (255-262 mm, the confirmed rig), ~297.5 (290-305 mm, the same kind of
/// sub-5%-of-focal-length jitter around one train), and 385 mm.** Every gap
/// between those six is >=11% (135->180 is 33%, 180->257.5 is 43%,
/// 257.5->297.5 is 15.5%, 297.5->385 is 29%), safely above the 2% merge
/// threshold, so distinct optics never collapse together. The same rule
/// applied to a Canon EOS R8 in the same library (a zoom lens genuinely used
/// at 16/28/35/40/45/50/53/64/70 mm) changes NOTHING -- every real step
/// there is already >=10% apart.
public enum FocalLengthBucketing {
    /// 5/250 == this. Any two adjacent 5 mm buckets at or above 250 mm sit
    /// within this relative tolerance of each other; below 250 mm, ordinary
    /// plate-solve jitter (a few mm) stays inside a single 5 mm bucket in
    /// the first place, so the two-step rule needs no extra merge there.
    private static let mergeToleranceRelative = 0.02
    private static let bucketWidthMM = 5.0

    /// Builds the `[roundedRawValue: canonicalValue]` lookup for one
    /// camera's raw `FOCALLEN` readings. Every distinct 5 mm bucket that
    /// occurs in `rawValues` is a key; buckets that single-link-merge share
    /// the same canonical value (their members' median, so display always
    /// lands on a multiple of 2.5 mm). `[:]` for empty input.
    public static func clusters(_ rawValues: some Sequence<Double>) -> [Double: Double] {
        let rounded = Set(rawValues.map { roundToBucketWidth($0) }).sorted()
        guard !rounded.isEmpty else { return [:] }

        var groups: [[Double]] = [[rounded[0]]]
        for value in rounded.dropFirst() {
            let previous = groups[groups.count - 1][groups[groups.count - 1].count - 1]
            let relativeDelta = (value - previous) / previous
            if relativeDelta <= mergeToleranceRelative {
                groups[groups.count - 1].append(value)
            } else {
                groups.append([value])
            }
        }

        var result: [Double: Double] = [:]
        for group in groups {
            let canonical = median(group)
            for value in group { result[value] = canonical }
        }
        return result
    }

    /// Canonicalizes one raw mm value against a `buckets` table already
    /// built by `clusters(_:)` from every raw value observed for the SAME
    /// camera. Rounds to the nearest 5 mm first, then looks that up in
    /// `buckets` -- falling back to the plain rounding when `buckets` has
    /// nothing for it (camera never seen when the table was built, or an
    /// empty table).
    public static func canonicalize(_ raw: Double, buckets: [Double: Double]) -> Double {
        let rounded = roundToBucketWidth(raw)
        return buckets[rounded] ?? rounded
    }

    private static func roundToBucketWidth(_ value: Double) -> Double {
        (value / bucketWidthMM).rounded() * bucketWidthMM
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
