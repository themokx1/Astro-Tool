import Foundation

/// One frame's plate-solved field geometry, derived entirely from its
/// already-scanned `header_json` blob (same "never touch the filesystem"
/// convention as `TargetCoordinates`) plus its `NAXIS1`/`NAXIS2` dimensions.
/// `path` is NOT filled in by `FieldGeometry.frameField` itself (that
/// function only sees a header blob, not the file it came from) -- callers
/// that need it (`FieldGeometry.panels`) set it on the returned value, which
/// is why every field here is a mutable `var`.
public struct FrameField: Codable, Sendable {
    public var path: String
    public var raDeg: Double
    public var decDeg: Double
    /// Field-rotation angle in degrees, derived from the WCS `CD` matrix
    /// (`atan2(CD1_2, CD1_1)`) -- `nil` when the header has no (full) `CD`
    /// matrix, since the `XPIXSZ`/`FOCALLEN` fallback scale carries no
    /// rotation information at all.
    public var rotationDeg: Double?
    /// Arcsec-per-pixel scale, either from the WCS `CD` matrix's determinant
    /// (`sqrt(|det CD|) * 3600`) or, when no full `CD` matrix is present,
    /// the same `206.265 * xpixsz(µm) / focallen(mm)` fallback
    /// `SessionQuality.pixelScaleArcsec` uses. `nil` when neither source is
    /// available.
    public var pixelScaleArcsec: Double?
    /// Field-of-view width/height in degrees (`NAXIS1`/`NAXIS2` × pixel
    /// scale), `nil` whenever `pixelScaleArcsec` or the matching `NAXISn` is
    /// missing.
    public var fovWidthDeg: Double?
    public var fovHeightDeg: Double?

    public init(
        path: String,
        raDeg: Double,
        decDeg: Double,
        rotationDeg: Double? = nil,
        pixelScaleArcsec: Double? = nil,
        fovWidthDeg: Double? = nil,
        fovHeightDeg: Double? = nil
    ) {
        self.path = path
        self.raDeg = raDeg
        self.decDeg = decDeg
        self.rotationDeg = rotationDeg
        self.pixelScaleArcsec = pixelScaleArcsec
        self.fovWidthDeg = fovWidthDeg
        self.fovHeightDeg = fovHeightDeg
    }
}

/// One mosaic panel: a cluster of a target's usable lights whose plate-solved
/// field centers sit close together, distinct from another panel's cluster
/// far enough away that they're clearly separate pointings rather than
/// dithered frames of the same field.
public struct Panel: Codable, Sendable {
    /// "A", "B", "C", ... assigned after sorting panels by `frameCount`
    /// descending -- the panel with the most frames is always "A".
    public var label: String
    /// Vector-mean (unit-sphere average, NOT a naive arithmetic mean --
    /// see `FieldGeometry.panels`'s doc for why) RA/Dec across the panel's
    /// frames, in degrees.
    public var centerRaDeg: Double
    public var centerDecDeg: Double
    public var frameCount: Int
    /// Sum of `exptime` across the panel's frames; frames with no `exptime`
    /// contribute 0, same convention as `SessionDetail.integrationSeconds`.
    public var integrationSeconds: Double
    /// Median `rotationDeg` across the panel's frames that have one, `nil`
    /// if none do.
    public var rotationDeg: Double?
    /// Median `pixelScaleArcsec` across the panel's frames that have one,
    /// `nil` if none do.
    public var pixelScaleArcsec: Double?

    public init(
        label: String,
        centerRaDeg: Double,
        centerDecDeg: Double,
        frameCount: Int,
        integrationSeconds: Double,
        rotationDeg: Double? = nil,
        pixelScaleArcsec: Double? = nil
    ) {
        self.label = label
        self.centerRaDeg = centerRaDeg
        self.centerDecDeg = centerDecDeg
        self.frameCount = frameCount
        self.integrationSeconds = integrationSeconds
        self.rotationDeg = rotationDeg
        self.pixelScaleArcsec = pixelScaleArcsec
    }
}

/// A target's full panel breakdown (R6-3): how many distinct field-center
/// clusters its usable lights fall into, and whether their integration is
/// balanced across panels -- the mosaic-seam-SNR-step failure mode this
/// whole feature exists to surface.
public struct PanelReport: Codable, Sendable {
    public var target: String
    public var panels: [Panel]
    /// `true` when `panels.count >= 2` -- a single field is not a mosaic.
    public var isMosaic: Bool
    /// `true` when at least two panels have nonzero integration and the
    /// ratio between the largest and smallest of those exceeds 1.5 -- e.g.
    /// panel A at 2:10 vs. panel C at 0:35 (ratio ~3.7). `false` for a
    /// single-field report, or when fewer than two panels have any
    /// integration to compare at all.
    public var isUnbalanced: Bool

    public init(target: String, panels: [Panel], isMosaic: Bool, isUnbalanced: Bool) {
        self.target = target
        self.panels = panels
        self.isMosaic = isMosaic
        self.isUnbalanced = isUnbalanced
    }
}

/// Derives per-frame plate-solved field geometry from `header_json` and
/// clusters a target's usable lights into mosaic panels. Read-only against
/// `Database` -- never touches the filesystem, same convention as every
/// other `Stats`/`Sky` query type.
public enum FieldGeometry {
    /// Ratio applied to the median known FOV width to get the panel
    /// join-threshold (separations at or under this count as "the same
    /// panel").
    private static let joinThresholdFOVRatio = 0.5
    /// Fallback join-threshold, in degrees, when not a single usable frame
    /// has a derivable FOV (no `CD` matrix and no `XPIXSZ`/`FOCALLEN` pair
    /// on any of them).
    private static let fallbackJoinThresholdDeg = 1.0
    /// Above this max/min integration ratio (among panels with nonzero
    /// integration), a mosaic counts as unbalanced.
    private static let unbalancedRatioThreshold = 1.5

    /// One frame's field geometry from its `header_json` (plus `NAXIS1`/
    /// `NAXIS2`, needed for the FOV size). Requires `CRVAL1`/`CRVAL2` (the
    /// plate-solved field center) -- `nil` when either is missing, same as
    /// `TargetCoordinates.coordinates` requiring a WCS solution. `path` on
    /// the returned value is always `""`; the caller fills in the real path
    /// (see the struct's own doc for why).
    public static func frameField(headerJSON: String?, naxis1: Int?, naxis2: Int?) -> FrameField? {
        guard let headerJSON, let data = headerJSON.data(using: .utf8),
              let cards = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        let header = FITSHeader(rawValues: cards)

        guard let crval1 = header.double("CRVAL1"), let crval2 = header.double("CRVAL2") else { return nil }

        var rotationDeg: Double?
        var pixelScale: Double?

        if let cd11 = header.double("CD1_1"), let cd12 = header.double("CD1_2"),
           let cd21 = header.double("CD2_1"), let cd22 = header.double("CD2_2")
        {
            let determinant = cd11 * cd22 - cd12 * cd21
            pixelScale = sqrt(abs(determinant)) * 3600
            rotationDeg = atan2(cd12, cd11) * 180 / .pi
        } else if let xpixsz = header.double("XPIXSZ"), let focallen = header.double("FOCALLEN") {
            pixelScale = SessionQuality.pixelScaleArcsec(xpixsz: xpixsz, focallen: focallen)
        }

        var fovWidth: Double?
        var fovHeight: Double?
        if let pixelScale, let naxis1, let naxis2 {
            fovWidth = Double(naxis1) * pixelScale / 3600
            fovHeight = Double(naxis2) * pixelScale / 3600
        }

        return FrameField(
            path: "",
            raDeg: crval1,
            decDeg: crval2,
            rotationDeg: rotationDeg,
            pixelScaleArcsec: pixelScale,
            fovWidthDeg: fovWidth,
            fovHeightDeg: fovHeight
        )
    }

    /// Clusters `target`'s usable session lights (deduped via
    /// `FrameSet.lightBuckets`, across every session date on record) into
    /// mosaic panels by their plate-solved field centers. Frames with no
    /// resolvable `frameField` (no WCS solution at all) are silently
    /// excluded -- there's nowhere to place them.
    ///
    /// Clustering is greedy single-linkage: two frames join the same panel
    /// when their great-circle separation (`SunMoon.angularSeparationDeg`)
    /// is at or under the join-threshold (half the median known FOV width,
    /// or `fallbackJoinThresholdDeg` when no frame's FOV is known) --
    /// equivalently, the connected components of the graph where an edge
    /// joins any two frames within that threshold. Implemented via a plain
    /// union-find over frame indices.
    ///
    /// Each panel's center is the vector mean (average unit vector on the
    /// sphere, renormalized back to RA/Dec) of its member frames' centers --
    /// NOT a naive arithmetic mean of RA values, which would badly misplace
    /// a cluster straddling the 0°/360° RA wraparound (e.g. centers at
    /// 359.9° and 0.1° would naively average to 180.0°, the opposite side of
    /// the sky, instead of ~0.0°).
    public static func panels(target: String, db: Database, config: AstroConfig) throws -> PanelReport {
        let files = try db.allFiles(includeMissing: false)
        let lights = files.filter { $0.target == target && $0.area == .sessions && $0.role == .light }
        guard !lights.isEmpty else {
            return PanelReport(target: target, panels: [], isMosaic: false, isUnbalanced: false)
        }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in lights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: lights, meta: metaByFileID, config: config)

        var fields: [FrameField] = []
        var integrationSeconds: [Double] = []
        for file in buckets.usable {
            guard let id = file.id, let meta = metaByFileID[id],
                  var field = frameField(headerJSON: meta.headerJSON, naxis1: meta.naxis1, naxis2: meta.naxis2)
            else { continue }
            field.path = file.path
            fields.append(field)
            integrationSeconds.append(meta.exptime ?? 0)
        }

        guard !fields.isEmpty else {
            return PanelReport(target: target, panels: [], isMosaic: false, isUnbalanced: false)
        }

        let knownFOVWidths = fields.compactMap(\.fovWidthDeg)
        let joinThreshold = knownFOVWidths.isEmpty
            ? fallbackJoinThresholdDeg
            : joinThresholdFOVRatio * TargetCoordinates.median(knownFOVWidths)

        let clusterOf = clusterIndices(fields: fields, joinThresholdDeg: joinThreshold)

        var indicesByCluster: [Int: [Int]] = [:]
        for (index, cluster) in clusterOf.enumerated() {
            indicesByCluster[cluster, default: []].append(index)
        }

        var builtPanels: [Panel] = indicesByCluster.values.map { indices in
            buildPanel(indices: indices, fields: fields, integrationSeconds: integrationSeconds)
        }

        builtPanels.sort { $0.frameCount > $1.frameCount }
        for index in builtPanels.indices {
            builtPanels[index].label = label(forIndex: index)
        }

        let isMosaic = builtPanels.count >= 2
        let nonZeroIntegrations = builtPanels.map(\.integrationSeconds).filter { $0 > 0 }
        let isUnbalanced: Bool
        if nonZeroIntegrations.count >= 2, let maxValue = nonZeroIntegrations.max(), let minValue = nonZeroIntegrations.min() {
            isUnbalanced = maxValue / minValue > unbalancedRatioThreshold
        } else {
            isUnbalanced = false
        }

        return PanelReport(target: target, panels: builtPanels, isMosaic: isMosaic, isUnbalanced: isUnbalanced)
    }

    // MARK: - Clustering

    /// Union-find over `fields`' indices: joins `i`/`j` whenever their
    /// great-circle separation is at or under `joinThresholdDeg`. Returns
    /// each index's final (fully path-compressed) root -- callers group by
    /// this value to get the connected components.
    private static func clusterIndices(fields: [FrameField], joinThresholdDeg: Double) -> [Int] {
        var parent = Array(fields.indices)

        func find(_ x: Int) -> Int {
            var current = x
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        func union(_ a: Int, _ b: Int) {
            let rootA = find(a)
            let rootB = find(b)
            guard rootA != rootB else { return }
            parent[rootA] = rootB
        }

        for i in fields.indices {
            for j in (i + 1)..<fields.count {
                let separation = SunMoon.angularSeparationDeg(
                    ra1: fields[i].raDeg, dec1: fields[i].decDeg,
                    ra2: fields[j].raDeg, dec2: fields[j].decDeg
                )
                if separation <= joinThresholdDeg { union(i, j) }
            }
        }

        return fields.indices.map(find)
    }

    // MARK: - Panel assembly

    private static func buildPanel(indices: [Int], fields: [FrameField], integrationSeconds: [Double]) -> Panel {
        let members = indices.map { fields[$0] }

        var sumX = 0.0, sumY = 0.0, sumZ = 0.0
        for field in members {
            let raRad = field.raDeg * .pi / 180
            let decRad = field.decDeg * .pi / 180
            sumX += cos(decRad) * cos(raRad)
            sumY += cos(decRad) * sin(raRad)
            sumZ += sin(decRad)
        }
        let count = Double(members.count)
        sumX /= count; sumY /= count; sumZ /= count

        var centerRaDeg = atan2(sumY, sumX) * 180 / .pi
        if centerRaDeg < 0 { centerRaDeg += 360 }
        let centerDecDeg = atan2(sumZ, sqrt(sumX * sumX + sumY * sumY)) * 180 / .pi

        let rotations = members.compactMap(\.rotationDeg)
        let scales = members.compactMap(\.pixelScaleArcsec)
        let integration = indices.map { integrationSeconds[$0] }.reduce(0, +)

        return Panel(
            label: "",
            centerRaDeg: centerRaDeg,
            centerDecDeg: centerDecDeg,
            frameCount: members.count,
            integrationSeconds: integration,
            rotationDeg: rotations.isEmpty ? nil : TargetCoordinates.median(rotations),
            pixelScaleArcsec: scales.isEmpty ? nil : TargetCoordinates.median(scales)
        )
    }

    /// "A", "B", ..., "Z", then "AA", "AB", ... -- plain base-26 letter
    /// labeling, more than enough for any realistic panel count.
    private static func label(forIndex index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard index >= letters.count else { return String(letters[index]) }
        let first = index / letters.count - 1
        let second = index % letters.count
        return String(letters[first]) + String(letters[second])
    }
}
