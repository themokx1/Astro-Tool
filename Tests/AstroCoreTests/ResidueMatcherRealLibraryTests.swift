import Foundation
import Testing
@testable import AstroCore

// MARK: - Broadened default residue patterns, pinned against a real library
//
// `AstroConfig.residuePatterns`'s original 8 defaults (`*.seq`, `*.lst`,
// `*_conv*`, `*_bkg*`, `*_pp_*`, `r_*`, `bkg_*`, `.DS_Store`) were designed
// around Siril/PixInsight intermediate-file conventions, not around the
// stack-PRODUCT names (`starless_*`, `starmask_*`, `VeraLux_*`, ...) that
// `Scan/Scanner.swift`'s IMAGETYP-promotion bug actually let through. Of the
// 48 real wrongly-promoted rows confirmed against a copy of the owner's
// library, the original defaults caught only 1.
//
// The obvious next step -- add `starless*`/`starmask*`/`graxpert_result*` to
// the default list too, since those account for most of the 48 -- was tried
// and REVERTED: `Stats/StackDiscovery.swift` hardcodes this exact default
// list (`ResidueMatcher.matchesFilePattern(name:, config: AstroConfig())`)
// to decide what to skip as junk in the `stacks/`/`processed/` areas, where
// `starless`/`starmask`/`graxpert`-processed files are first-class, WANTED
// `StackVariantKind` output (`.starless`/`.starmask`/`.edited`), not
// residue. Adding those tokens broke 6 real tests (`StackDiscoveryTests`,
// `ResultsQueryTests`, `ResultsStoreTests`, `CLISmokeTests`) by making
// `looksLikeStackOutput` reject legitimate stack variants before
// variant-kind classification ever ran. Residue-ness for that vocabulary is
// AREA-dependent (junk loose in `sessions/`, a keeper in `stacks/`/
// `processed/`) -- a single flat global pattern list can't express that, so
// this fix only broadens the default with tokens that don't collide with
// `StackDiscovery`'s vocabulary anywhere in the codebase. See
// `AstroConfig.residuePatterns`'s own doc comment for the full list and
// reasoning. Reaching the other 38 (35 starless/starmask + 3 bare
// `Ha.fit`/`Oiii.fit`/`RGB.fit`) needs an area-scoped predicate, not just
// more global patterns -- tracked as a follow-up, not attempted here.

/// The 38 of the 48 wrongly-promoted paths deliberately left uncaught by
/// this change: 35 use `starless`/`starmask`/`graxpert_result` tokens that
/// collide with `StackDiscovery`'s `StackVariantKind` vocabulary (see the
/// file-level doc comment above), and the remaining 3 bare basenames
/// (`Ha.fit`/`Oiii.fit`/`RGB.fit`) are indistinguishable from a genuine
/// narrowband/RGB-combine sub's filename -- no residue pattern could catch
/// either group without risking misclassifying real, wanted content
/// elsewhere in the library.
private let honestRemainder: Set<String> = [
    "sessions/M42_Orion/2026-01-17/starless_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract.fit",
    "sessions/M42_Orion/2026-01-17/starless_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract_process.fit",
    "sessions/M42_Orion/2026-01-17/starless_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract_process2.fit",
    "sessions/M42_Orion/2026-01-17/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_2.fit",
    "sessions/M42_Orion/2026-01-17/starmask_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract.fit",
    "sessions/M42_Orion/2026-01-17/starmask_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract_process.fit",
    "sessions/M42_Orion/2026-01-17/starmask_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_2.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25/starless_NGC_2237_085x60sec_5100s_2026-03-01_1629_og_work.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25/starless_NGC_2237_085x60sec_5100s_2026-03-01_1629_og_work_streched.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25/starmask_NGC_2237_085x60sec_5100s_2026-03-01_1629_og_work.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Ha.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_HOO_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_HSO_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_SHO_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_stars_remove_at_full_res.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_starnet_two_x_test.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_workú.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_stars_remove_at_full_res.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_starnet_two_x_test.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_workú.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Oiii.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/RGB.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work_.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_HOO_Improved copy 2.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_HOO_Improved copy.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_HOO_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_HSO_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_OSH_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_SHO_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_resampled_alchemy_strech.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_resampled_strech.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_strech.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_r_osc_and_filtered_00002.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starmask_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work_.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_strech.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starmask_r_osc_and_filtered_00002.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/starless_NGC_2244_Satellite_Cluster_009x60sec_540s_2026-03-16_1958_og.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/starmask_NGC_2244_Satellite_Cluster_009x60sec_540s_2026-03-16_1958_og.fit",
]

@Test func broadenedResiduePatternsCatch10Of48RealWronglyPromotedFrames() throws {
    let config = AstroConfig()

    var caught: [String] = []
    var missed: [String] = []
    for path in RealLibraryResiduePaths.wronglyPromoted {
        if ResidueMatcher.isResidue(path: path, config: config) {
            caught.append(path)
        } else {
            missed.append(path)
        }
    }

    #expect(caught.count == 10)
    // Exactly the acknowledged remainder is missed -- not more (a pattern
    // regressed), not fewer (a pattern got broader than intended, which
    // would also need re-checking against `otherSessionLightPaths` below
    // AND against `StackDiscoveryTests`/`ResultsQueryTests`).
    #expect(Set(missed) == honestRemainder)
}

@Test func broadenedResiduePatternsNeverMatchAnyOtherRealSessionLightFrame() throws {
    let config = AstroConfig()

    let falsePositives = RealLibraryResiduePaths.otherSessionLightPaths.filter {
        ResidueMatcher.isResidue(path: $0, config: config)
    }

    #expect(
        falsePositives.isEmpty,
        "Broadened residue patterns wrongly matched \(falsePositives.count) real/other session light frame(s): \(falsePositives.prefix(5))"
    )
}

@Test func residueFilePatternMatchingIsCaseInsensitive() throws {
    // GlobMatcher already lowercases both sides -- this pins that existing
    // behavior, since the real library's polluted filenames are capitalized
    // (`VeraLux_...`, `Comet_Stack_work.fit`) while the patterns above are
    // written lowercase.
    var config = AstroConfig()
    config.residuePatterns = ["veralux_*", "*stack_work*"]

    #expect(ResidueMatcher.matchesFilePattern(name: "VERALUX_RESULT.FIT", config: config))
    #expect(ResidueMatcher.matchesFilePattern(name: "VeraLux_Alchemy_Linear.fit", config: config))
    #expect(ResidueMatcher.matchesFilePattern(name: "Comet_Stack_work.fit", config: config))
}

// MARK: - The combined guard: config patterns OR StackDiscovery classification
//
// `Scan/Scanner.swift`'s `isNonPromotableSessionResidue` adds a SECOND,
// code-driven check on top of `ResidueMatcher.isResidue`:
// `StackDiscovery.classifiesAsStackProduct` -- the exact same starless/
// starmask/edited/export recognition `stacks/`/`processed`-area variant
// grouping already applies, reused rather than re-implemented. These tests
// mirror that OR exactly (never re-deriving the match themselves) and pin
// its combined coverage/false-positive behavior against the same real
// library data.

/// The 3 of the 48 wrongly-promoted paths still uncaught even by the
/// combined guard: bare `Ha.fit`/`Oiii.fit`/`RGB.fit` basenames are
/// legitimate real narrowband/RGB-combine filter names too, and
/// `StackDiscovery.variantKind` classifies them `.original` (no starless/
/// starmask prefix, no edit marker, not an export extension) -- exactly the
/// same ambiguous bucket a genuine unmarked capture falls into. No safe
/// pattern or classifier rule exists to tell them apart from here.
private let combinedGuardHonestRemainder: Set<String> = [
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Ha.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Oiii.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/RGB.fit",
]

/// Exactly what `LibraryScanner.isNonPromotableSessionResidue` does --
/// duplicated here ONLY as a two-line OR of the two real engines (never a
/// re-implementation of either one's matching logic), since that method
/// itself is `private` to `Scanner.swift`.
private func isNonPromotableSessionResidue(path: String, config: AstroConfig) -> Bool {
    if ResidueMatcher.isResidue(path: path, config: config) { return true }
    let fileName = (path as NSString).lastPathComponent
    return StackDiscovery.classifiesAsStackProduct(fileName: fileName)
}

@Test func combinedGuardCatches45Of48RealWronglyPromotedFramesIncludingStarlessStarmaskGraxpert() throws {
    let config = AstroConfig()

    var caught: [String] = []
    var missed: [String] = []
    for path in RealLibraryResiduePaths.wronglyPromoted {
        if isNonPromotableSessionResidue(path: path, config: config) {
            caught.append(path)
        } else {
            missed.append(path)
        }
    }

    #expect(caught.count == 45)
    #expect(Set(missed) == combinedGuardHonestRemainder)
}

@Test func combinedGuardNeverMatchesAnyScannerReachableCleanSessionLightFrame() throws {
    let config = AstroConfig()

    let falsePositives = RealLibraryResiduePaths.scannerReachableCleanPaths.filter {
        isNonPromotableSessionResidue(path: $0, config: config)
    }

    #expect(
        falsePositives.isEmpty,
        "Combined guard wrongly matched \(falsePositives.count) real/other session light frame(s): \(falsePositives.prefix(5))"
    )
}

@Test func resultHaAndResultOIIIStackedIntegrationsStayHonestRemainderNotAnInventedPattern() throws {
    // Flagged while building fixtures for the prior commit: these two rows
    // are ALSO wrongly promoted (imagetyp=Light, but the filename bakes in a
    // 12720s total integration and the file sits in a `results/` folder --
    // not a real single sub), yet their `fits_meta.filter` values (Ha/OIII)
    // are legitimate real filter names, and `StackDiscovery.variantKind`
    // classifies `"result_Ha_12720s.fit"`/`"result_OIII_12720s.fit"` as
    // `.original` (no starless/starmask/edit marker). Per instructions: do
    // NOT invent a `result_*` residue pattern to catch these -- pin them as
    // a deliberate, disclosed remainder instead.
    let config = AstroConfig()
    #expect(!isNonPromotableSessionResidue(
        path: "sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_Ha_12720s.fit", config: config
    ))
    #expect(!isNonPromotableSessionResidue(
        path: "sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_OIII_12720s.fit", config: config
    ))
}
