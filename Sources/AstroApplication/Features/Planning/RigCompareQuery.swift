import AstroCore
import Foundation

/// One catalog target's FOV-fit comparison across the owner's currently
/// selected setup and the OTHER saved setup ("melyik géppel fér be?", expert
/// ideation #2) -- built by `RigCompareQuery.compare` from two independent
/// `DiscoveryPlanner.discover` sweeps, one per setup's own field of view,
/// zipped together on `CatalogTarget.designation`.
public struct RigCompareRow: Sendable, Equatable {
    public let designation: String
    /// The currently selected setup's own framing verdict for this target,
    /// reusing `PlanningQuery`'s `PlanningFit` vocabulary (and its existing
    /// `hu.lproj` translations) rather than inventing a second one.
    /// `DiscoveryPlanner.fovComposition`'s five literal Hungarian labels use
    /// the EXACT SAME 0.08/0.18/0.75/1.1 thresholds
    /// `PlanningQuery.composition` does, so mapping its label text back onto
    /// `PlanningFit` (see `RigCompareQuery.fit(for:)`) is a faithful
    /// re-labeling of the identical classification, never a second opinion.
    /// `nil` only when the selected setup's FOV or the target's own size is
    /// unknown -- the same `nil` contract `DiscoveryRow.fovFitLabel` itself
    /// documents.
    public let primaryFit: PlanningFit?
    /// Same, for the OTHER (comparison) setup.
    public let otherFit: PlanningFit?

    public init(designation: String, primaryFit: PlanningFit?, otherFit: PlanningFit?) {
        self.designation = designation
        self.primaryFit = primaryFit
        self.otherFit = otherFit
    }
}

/// Answers "which of my two rigs actually frames this target well?" by
/// running `DiscoveryPlanner.discover` a SECOND time, for a second setup's
/// FOV, and zipping the two result sets by designation -- `DiscoveryPlanner`
/// itself is never touched; this is a second, read-only consumer of the
/// exact sky/FOV math `PlanningQuery` already runs for its own single
/// selected setup.
public enum RigCompareQuery {
    /// `nil` whenever there is nothing honest to compare: fewer than two
    /// saved setups, the selected ID no longer matches any of them, or
    /// either setup's field of view can't be resolved at its own focal
    /// length (`ImagingSetupProfile.fieldOfView` already returns `nil` for a
    /// corrupt hand-edited profile -- see its own doc). `PlanningStore` is
    /// the intended caller; it already hides its "compare" toggle whenever
    /// this would be `nil` on the `setups.count < 2` account, matching the
    /// feature's own "stays hidden, no setups CRUD is built for this" scope.
    ///
    /// The OTHER setup is the first saved setup whose `id` is not
    /// `selectedSetupID`, in `setups`' own declaration order -- the owner's
    /// actual "I run two rigs" scenario never has a third profile to
    /// disambiguate between; a longer hand-edited list still gets a
    /// deterministic pick rather than an error.
    public static func compare(
        selectedSetupID: String,
        setups: [ImagingSetupProfile],
        focalLengthMM: Double?,
        site: SiteRule,
        date: Date = Date(),
        minAltitudeDeg: Double = PlanningQuery.defaultMinAltitudeDeg,
        targets: [CatalogTarget] = TargetCatalog.all
    ) -> [String: RigCompareRow]? {
        guard setups.count >= 2,
              let primary = setups.first(where: { $0.id == selectedSetupID }),
              let other = setups.first(where: { $0.id != selectedSetupID }),
              let primaryFOV = primary.fieldOfView(at: focalLengthMM),
              let otherFOV = other.fieldOfView()
        else { return nil }

        // Pure sky placement is irrelevant here -- both sweeps only differ in
        // `setupFOVDeg`, so a target's placement-driven fields (altitude,
        // visibility, verdict, score) are deliberately never surfaced by this
        // query; only the FOV-fit label each sweep derives is compared.
        let primaryRows = DiscoveryPlanner.discover(
            date: date, site: site, minAltitudeDeg: minAltitudeDeg, targets: targets,
            setupFOVDeg: (width: primaryFOV.widthDeg, height: primaryFOV.heightDeg)
        )
        let otherRows = DiscoveryPlanner.discover(
            date: date, site: site, minAltitudeDeg: minAltitudeDeg, targets: targets,
            setupFOVDeg: (width: otherFOV.widthDeg, height: otherFOV.heightDeg)
        )
        let otherByDesignation = Dictionary(uniqueKeysWithValues: otherRows.map { ($0.target.designation, $0) })

        var result: [String: RigCompareRow] = [:]
        result.reserveCapacity(primaryRows.count)
        for row in primaryRows {
            let designation = row.target.designation
            result[designation] = RigCompareRow(
                designation: designation,
                primaryFit: fit(for: row.fovFitLabel),
                otherFit: fit(for: otherByDesignation[designation]?.fovFitLabel)
            )
        }
        return result
    }

    /// `DiscoveryPlanner.fovComposition`'s five literal Hungarian labels,
    /// mapped back onto `PlanningFit`'s own cases -- see `RigCompareRow
    /// .primaryFit`'s doc for why this is a faithful re-labeling rather than
    /// a guess. An unrecognized label (would mean `DiscoveryPlanner`'s own
    /// wording changed underneath this file, or there was nothing to label
    /// at all) maps to `nil` -- an honest "no opinion", never a wrong guess.
    private static func fit(for fovFitLabel: String?) -> PlanningFit? {
        switch fovFitLabel {
        case "mozaik kellene": .mosaic
        case "nagyon kicsi a képmezőben": .tooSmall
        case "kicsi, tág kompozíció": .wide
        case "jó kitöltés": .good
        case "szorosan fér be": .tight
        default: nil
        }
    }
}
