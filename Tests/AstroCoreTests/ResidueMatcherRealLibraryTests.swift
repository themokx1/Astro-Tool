import Foundation
import Testing
@testable import AstroCore

// MARK: - Residue recognition, pinned against a real library
//
// Three layers, each pinned separately against the same read-only copy of
// the owner's real `index.sqlite` (see `RealLibraryResiduePaths`):
//
//  1. UNIVERSAL patterns (`AstroConfig.residuePatterns`) -- match anywhere
//     in the library. `Stats/StackDiscovery.swift` hardcodes this exact
//     default list (`ResidueMatcher.matchesFilePattern(name:, config:
//     AstroConfig())`) to decide what to skip as junk in the `stacks/`/
//     `processed/` areas, so `starless`/`starmask`/`graxpert`/`result`
//     tokens can NEVER live here: that same vocabulary is first-class,
//     WANTED `StackVariantKind`/`looksLikeStackOutput` output there.
//     Adding them was tried and REVERTED (6 test failures across
//     `StackDiscoveryTests`, `ResultsQueryTests`, `ResultsStoreTests`,
//     `CLISmokeTests`).
//  2. SESSION-scoped patterns (`AstroConfig.sessionResiduePatterns`) --
//     consulted by `ResidueMatcher.category`/`isResidue` ONLY for paths
//     whose `PathClassifier` area is `.sessions`. This is where the
//     colliding vocabulary lives: junk loose in `sessions/`, a keeper in
//     `stacks/`/`processed/`. Feeds BOTH `CleanupReport` (via `category`)
//     and `LibraryScanner`'s IMAGETYP-promotion guard (via `isResidue`).
//  3. CODE-driven recognition (`StackDiscovery.classifiesAsStackProduct`)
//     -- `LibraryScanner`'s promotion guard consults it as an extra,
//     config-independent backstop so a `starless_*` byproduct is never
//     promoted even if the owner's `config.json` empties the pattern lists.

/// The 43 of the 53 wrongly-promoted paths the UNIVERSAL default patterns
/// alone leave uncaught: 40 use `starless`/`starmask`/`graxpert`/`result_`
/// tokens that collide with `StackDiscovery`'s vocabulary (they live in
/// `sessionResiduePatterns` instead -- see the file-level comment), and the
/// remaining 3 bare basenames (`Ha.fit`/`Oiii.fit`/`RGB.fit`) are
/// indistinguishable from a genuine narrowband/RGB-combine sub's filename.
private let universalPatternRemainder: Set<String> = [
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
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_strech.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_HOO_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_HSO_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_SHO_Improved.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_strech.fit",
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
    "sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_Ha_12720s.fit",
    "sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_OIII_12720s.fit",
]

/// The 3 of the 53 wrongly-promoted paths no layer can safely catch: bare
/// `Ha.fit`/`Oiii.fit`/`RGB.fit` basenames are legitimate real
/// narrowband/RGB-combine filter names too, and
/// `StackDiscovery.variantKind` classifies them `.original` (no starless/
/// starmask prefix, no edit marker, not an export extension) -- exactly the
/// same ambiguous bucket a genuine unmarked capture falls into. No safe
/// pattern or classifier rule exists to tell them apart from here.
private let honestRemainder: Set<String> = [
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Ha.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Oiii.fit",
    "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/RGB.fit",
]

// MARK: - Layer 1: universal patterns (the list StackDiscovery also uses)

@Test func universalPatternsCatch10Of53RealWronglyPromotedFrames() throws {
    let config = AstroConfig()

    var caught: [String] = []
    var missed: [String] = []
    for path in RealLibraryResiduePaths.wronglyPromoted {
        let name = (path as NSString).lastPathComponent
        if ResidueMatcher.matchesFilePattern(name: name, config: config) {
            caught.append(path)
        } else {
            missed.append(path)
        }
    }

    #expect(caught.count == 10)
    // Exactly the acknowledged remainder is missed -- not more (a pattern
    // regressed), not fewer (a universal pattern got broader than intended,
    // which would also need re-checking against `otherSessionLightPaths`
    // below AND against `StackDiscoveryTests`/`ResultsQueryTests`).
    #expect(Set(missed) == universalPatternRemainder)
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

// MARK: - Layer 2: session-area-scoped patterns

@Test func sessionResiduePatternsOnlyApplyInTheSessionsArea() throws {
    let config = AstroConfig()

    // Junk when loose in a session date dir...
    #expect(ResidueMatcher.isResidue(
        path: "sessions/M42_Orion/2026-01-17/starless_result.fit", config: config))
    #expect(ResidueMatcher.category(
        forPath: "sessions/M42_Orion/2026-01-17/starless_result.fit", config: config) == "residue-session")

    // ...a first-class keeper everywhere StackDiscovery groups variants.
    // These exact stacks/processed twins of `wronglyPromoted`'s two
    // `result_*` rows exist in the real library (same basename, wanted
    // there) -- the sharpest possible demonstration of why this vocabulary
    // is area-scoped, not universal.
    #expect(!ResidueMatcher.isResidue(
        path: "stacks/NGC_7000_North_American_Nebula/2026-05-23/Mono/result_Ha_12720s.fit", config: config))
    #expect(!ResidueMatcher.isResidue(
        path: "processed/NGC_7000_North_American_Nebula/2026-05-23/Mono/result_OIII_12720s.fit", config: config))
    #expect(!ResidueMatcher.isResidue(
        path: "stacks/M42_Orion/2026-01-17/starless_result.fit", config: config))
}

@Test func toolOutputDirStillShieldsSessionResiduePatternMatches() throws {
    // `Stack/` (LightFrameRater's triage folder) is a `toolOutputDirNames`
    // entry -- anything under it is known-intentional tool output, never
    // residue, and that guard must keep beating the session-scoped patterns
    // exactly as it already beats the universal ones.
    let config = AstroConfig()
    #expect(ResidueMatcher.category(
        forPath: "sessions/M42_Orion/2026-01-17/Stack/starless_result.fit", config: config) == nil)
}

@Test func emptyingSessionResiduePatternsDisablesTheSessionLayer() throws {
    // The session layer is config-driven: an owner who deliberately empties
    // the list gets pattern-free behavior back (the Scanner's promotion
    // guard still has the config-independent StackDiscovery backstop).
    var config = AstroConfig()
    config.sessionResiduePatterns = []
    #expect(!ResidueMatcher.isResidue(
        path: "sessions/M42_Orion/2026-01-17/starless_result.fit", config: config))
}

@Test func sessionAwareIsResidueCatches50Of53RealWronglyPromotedFrames() throws {
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

    #expect(caught.count == 50)
    #expect(Set(missed) == honestRemainder)
}

/// The ONLY `otherSessionLightPaths` rows the session-aware `isResidue`
/// matches: starless/starmask byproducts the user dumped INSIDE a real
/// `lights/` folder. Correct matches (they ARE Siril stack byproducts --
/// `CleanupReport` listing them is the point of the session layer), and
/// harmless for the Scanner: their `role=.light` comes from the `lights/`
/// path itself, a shape `refineLooseFrameRole`/`healStaleClassification`
/// never evaluates (both are gated on path-role `.other` first).
private let byproductsInsideRealLightsFolders: Set<String> = [
    "sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process.fit",
    "sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_strechy.fit",
    "sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_strechy_2.fit",
    "sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_strechy_overstreched.fit",
    "sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_strechy_veraluxú.fit",
    "sessions/M42_Orion/2026-01-17/lights/starmask_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process.fit",
]

@Test func sessionAwareIsResidueMatchesOnlyKnownByproductsAmongOtherRealSessionLightFrames() throws {
    let config = AstroConfig()

    let matches = RealLibraryResiduePaths.otherSessionLightPaths.filter {
        ResidueMatcher.isResidue(path: $0, config: config)
    }

    #expect(
        Set(matches) == byproductsInsideRealLightsFolders,
        "Session-aware isResidue matched an unexpected set among real session light frames: \(matches.prefix(8))"
    )
}

// MARK: - Layer 3: the combined Scanner guard (patterns OR StackDiscovery)
//
// `Scan/Scanner.swift`'s `isNonPromotableSessionResidue` ORs the
// config-driven `ResidueMatcher.isResidue` with the code-driven
// `StackDiscovery.classifiesAsStackProduct` -- the exact same starless/
// starmask/edited/export recognition `stacks/`/`processed`-area variant
// grouping already applies, reused rather than re-implemented. These tests
// mirror that OR exactly (never re-deriving the match themselves) and pin
// its combined coverage/false-positive behavior against the same real
// library data.

/// Exactly what `LibraryScanner.isNonPromotableSessionResidue` does --
/// duplicated here ONLY as a two-line OR of the two real engines (never a
/// re-implementation of either one's matching logic), since that method
/// itself is `private` to `Scanner.swift`.
private func isNonPromotableSessionResidue(path: String, config: AstroConfig) -> Bool {
    if ResidueMatcher.isResidue(path: path, config: config) { return true }
    let fileName = (path as NSString).lastPathComponent
    return StackDiscovery.classifiesAsStackProduct(fileName: fileName)
}

@Test func combinedGuardCatches50Of53RealWronglyPromotedFrames() throws {
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

    #expect(caught.count == 50)
    #expect(Set(missed) == honestRemainder)
}

@Test func combinedGuardStillCatchesStarlessStarmaskWhenSessionPatternsAreEmptied() throws {
    // The StackDiscovery backstop is code, not config: even with BOTH
    // pattern lists emptied, a starless/starmask byproduct is still
    // non-promotable. (`result_*` names are the session-pattern layer's
    // sole responsibility -- variantKind sees them as `.original` -- so
    // they correctly fall through here; that's what
    // `sessionResiduePatterns`'s default exists for.)
    var config = AstroConfig()
    config.residuePatterns = []
    config.sessionResiduePatterns = []

    #expect(isNonPromotableSessionResidue(
        path: "sessions/M42_Orion/2026-01-17/starless_result.fit", config: config))
    #expect(!isNonPromotableSessionResidue(
        path: "sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_Ha_12720s.fit", config: config))
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

@Test func resultHaAndResultOIIIStackedIntegrationsAreCaughtBySessionPatterns() throws {
    // Flagged while building fixtures for the prior commit: these two rows
    // are wrongly promoted too (imagetyp=Light, but the filename bakes in a
    // 12720s total integration and the file sits in a `results/` folder --
    // not a real single sub), yet their `fits_meta.filter` values (Ha/OIII)
    // are legitimate real filter names and `StackDiscovery.variantKind`
    // classifies the basename `.original`, so neither the fake-filter
    // survey nor the code-driven backstop can reach them. The session-area
    // `result_*` pattern is what catches them -- verified against the DB
    // copy to match zero genuine session subs (its only other session-area
    // hits are `result_work.fit`-style Siril byproducts, equally junk).
    let config = AstroConfig()
    #expect(isNonPromotableSessionResidue(
        path: "sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_Ha_12720s.fit", config: config
    ))
    #expect(isNonPromotableSessionResidue(
        path: "sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_OIII_12720s.fit", config: config
    ))
}
