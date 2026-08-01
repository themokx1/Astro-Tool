/// Decides whether a target should be treated as wide-field (short focal
/// length / camera-lens rig) rather than narrow-field/deep-sky, purely from
/// already-loaded records -- no database access here, so it can be unit
/// tested directly and reused by `StatsQueries`.
public enum WideFieldHeuristic {
    /// - Parameters:
    ///   - target: the target name, used for the manual-override lookup and
    ///     the name-marker check.
    ///   - files: the target's session light frames (role `.light`, area
    ///     `.sessions`) -- callers are responsible for that filtering.
    ///   - meta: FITS/image metadata keyed by `FileRecord.id`, for whichever
    ///     of `files` have a row.
    ///   - rule: the configured thresholds/markers/overrides.
    ///
    /// Order of evaluation:
    /// 1. `rule.overrides[target]`, if present, wins outright (both `true`
    ///    and `false` short-circuit everything below).
    /// 2. Otherwise wide-field if ANY of: the target name contains a name
    ///    marker; a majority (>50%) of `files` have a wide-field extension;
    ///    or the median of known focal lengths among `files` is below
    ///    `rule.maxFocalLengthMM` (median rather than "any" so a single
    ///    stray short/long value can't flip the result on its own).
    public static func isWideField(
        target: String,
        files: [FileRecord],
        meta: [Int64: FITSMetaRecord],
        rule: WideFieldRule
    ) -> Bool {
        if let override = rule.overrides[target] {
            return override
        }

        let nameLower = target.lowercased()
        if rule.nameMarkers.contains(where: { !$0.isEmpty && nameLower.contains($0.lowercased()) }) {
            return true
        }

        if !files.isEmpty {
            let wideExtensions = Set(rule.extensions.map { $0.lowercased() })
            let matches = files.filter { wideExtensions.contains($0.ext.lowercased()) }.count
            if Double(matches) / Double(files.count) > 0.5 {
                return true
            }
        }

        let focalLengths = files.compactMap { file -> Double? in
            guard let id = file.id else { return nil }
            return meta[id]?.focallen
        }
        if !focalLengths.isEmpty, median(of: focalLengths) < rule.maxFocalLengthMM {
            return true
        }

        return false
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 {
            return sorted[count / 2]
        }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
}
