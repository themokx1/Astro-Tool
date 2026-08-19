/// Root-relative `sessions/`-area `role='light'` paths pulled from a
/// read-only copy of the owner's real `index.sqlite` (never the live file --
/// see the v0.x residue-pattern-broadening fix's own report for provenance).
/// Paths only: target names, session dates, and camera settings baked into
/// filenames, nothing personally identifying. Used to pin the default
/// `AstroConfig.residuePatterns` broadening decision against regressions --
/// both lists are DATA, not something to hand-edit when a pattern changes;
/// re-derive them from the DB copy instead.
enum RealLibraryResiduePaths {
    /// The 48 session-area FITS files confirmed wrongly promoted to
    /// `role=.light` by the pre-fix `refineLooseFrameRole`: Siril stack
    /// byproducts (starless/starmask/graxpert/composited results) sitting
    /// loose in a session date dir, whose FITS header inherited
    /// `IMAGETYP='Light Frame'` from the subs they were stacked from --
    /// `fits_meta.filter` on every one of these rows is `Starless`/`StarMask`/
    /// `R`/`mixed`, never a real filter name. Only 10 of the 48 are safely
    /// caught by the broadened default patterns -- see
    /// `AstroConfig.residuePatterns`'s own doc comment for why
    /// `starless`/`starmask`/`graxpert_result` (35 of the 48) are
    /// deliberately NOT part of the broadened default, plus 3 more
    /// (`Ha.fit`/`Oiii.fit`/`RGB.fit`) that are legitimate real filter names
    /// too.
    static let wronglyPromoted: [String] = rawWronglyPromoted
        .split(separator: "\n").map(String.init)

    /// A TRULY CLEAN negative fixture: every other session-area
    /// `role='light'` path in the same library -- genuine captured subs
    /// (FITS/CR3/TIFF), DSS/Siril sidecar files (`.info.txt`,
    /// `.stackinfo.txt`, thumbnail `.png`) -- with two categories
    /// deliberately excluded so "the broadened patterns match zero of
    /// these" is a meaningful, honest assertion rather than a trivially
    /// false one:
    ///  1. paths already matched by the PRE-broadening default patterns
    ///     (`.DS_Store` via `.DS_Store`, `r_osc_and_filtered_*.fit` via `r_*`,
    ///     a `*_pp_*`-matching preset `.json`) -- pre-existing, correct,
    ///     unrelated to this change.
    ///  2. 1 path (`VeraLux_StarComposer_result.fit`) that shares this
    ///     library's exact naming but happens to sit inside a real `lights/`
    ///     folder -- the SAME pollution as `wronglyPromoted`, just misplaced
    ///     by the user rather than IMAGETYP-promoted. The broadened patterns
    ///     catching it too (for `CleanupReport`'s cleanup summary) is a
    ///     correct bonus, not a false positive.
    static let otherSessionLightPaths: [String] = rawOtherSessionLightPaths
        .split(separator: "\n").map(String.init)

    /// The 35 `sessions`-area, role='light', `.fit`/`.fits`/`.fz`, path-role
    /// `.other` files -- i.e. exactly the shape `LibraryScanner`'s
    /// `refineLooseFrameRole`/`healStaleClassification` guards actually
    /// evaluate -- that are NOT in `wronglyPromoted` and that the COMBINED
    /// guard (`ResidueMatcher.isResidue` OR
    /// `StackDiscovery.classifiesAsStackProduct`) correctly leaves alone.
    /// Deliberately narrower than `otherSessionLightPaths` (which also
    /// includes thumbnail `.png`s and files already sitting inside a real
    /// `lights/` folder -- neither shape `LibraryScanner`'s guard ever
    /// actually sees, since it's gated on extension and path-role first).
    /// This is a MIX of genuine single-sub captures (`Light_..._0001.fit`
    /// timestamped frames) and `_og`/plain total-exposure-named finished
    /// STACKS with no edit marker at all -- `StackVariantKind.original`
    /// deliberately covers both (see `classifiesAsStackProduct`'s doc
    /// comment), since telling them apart isn't possible from the filename
    /// alone without risking a real sub. That means some of these 35 may
    /// still be undetected pollution the combined guard can't safely reach
    /// -- an honest, disclosed limitation, not a claim that all 35 are
    /// verified real subs.
    static let scannerReachableCleanPaths: [String] = rawScannerReachableCleanPaths
        .split(separator: "\n").map(String.init)

    private static let rawWronglyPromoted = """
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/Comet_Stack_work.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/comet_starless_r_bkg_pp_lights_stacked_work.fit
sessions/M42_Orion/2026-01-17/starless_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract.fit
sessions/M42_Orion/2026-01-17/starless_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract_process.fit
sessions/M42_Orion/2026-01-17/starless_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract_process2.fit
sessions/M42_Orion/2026-01-17/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_2.fit
sessions/M42_Orion/2026-01-17/starmask_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract.fit
sessions/M42_Orion/2026-01-17/starmask_FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract_process.fit
sessions/M42_Orion/2026-01-17/starmask_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_2.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/VeraLux_Alchemy_Linear.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/VeraLux_StarComposer_result.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/starless_NGC_2237_085x60sec_5100s_2026-03-01_1629_og_work.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/starless_NGC_2237_085x60sec_5100s_2026-03-01_1629_og_work_streched.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/starmask_NGC_2237_085x60sec_5100s_2026-03-01_1629_og_work.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Ha.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_HOO_Improved.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_HSO_Improved.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_SHO_Improved.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/Unsaved star recomposition result.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/VeraLux_StarComposer_result.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/VeraLux_StarComposer_result_og_size.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_stars_remove_at_full_res.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_starnet_two_x_test.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_workú.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_stars_remove_at_full_res.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_starnet_two_x_test.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_workú.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Oiii.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/RGB.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/S2_synt.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/VeraLux_Alchemy_Linear.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/fixstars.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work_.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_HOO_Improved copy 2.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_HOO_Improved copy.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_HOO_Improved.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_HSO_Improved.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_OSH_Improved.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work__result_SHO_Improved.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_resampled_alchemy_strech.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_resampled_strech.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_strech.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starless_r_osc_and_filtered_00002.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starmask_NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work_.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_strech.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/starmask_r_osc_and_filtered_00002.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/starless_NGC_2244_Satellite_Cluster_009x60sec_540s_2026-03-16_1958_og.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/starmask_NGC_2244_Satellite_Cluster_009x60sec_540s_2026-03-16_1958_og.fit
"""

    private static let rawOtherSessionLightPaths = """
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/FOV______017x60sec_1020s_drizzle-1-0x_2026-04-24_1806_og.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-042915_231deg_-10.0C_0009.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/individual_stacks/FOV______017x60sec_1020s_drizzle-1-0x_2026-04-24_1806_session1.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Autosave.tif
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Autosave001.tif
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Autosave002.tif
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Autosave003.tif
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Autosave004.tif
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Autosave005.tif
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Autosave006.tif
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-042915_231deg_-10.0C_0009.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-042915_231deg_-10.0C_0009.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043015_231deg_-10.0C_0010.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043015_231deg_-10.0C_0010.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043216_231deg_-10.0C_0011.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043216_231deg_-10.0C_0011.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043317_231deg_-10.0C_0012.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043317_231deg_-10.0C_0012.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043518_231deg_-10.0C_0013.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043518_231deg_-10.0C_0013.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043619_231deg_-10.0C_0014.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043619_231deg_-10.0C_0014.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043820_231deg_-10.1C_0015.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043820_231deg_-10.1C_0015.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043921_231deg_-10.0C_0016.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-043921_231deg_-10.0C_0016.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-044024_231deg_-10.0C_0017.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-044024_231deg_-10.0C_0017.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-044125_231deg_-10.0C_0018.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-044125_231deg_-10.0C_0018.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-044327_231deg_-10.0C_0019.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-044428_231deg_-10.0C_0020.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-044629_231deg_-10.0C_0021.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-044730_231deg_-10.0C_0022.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-044932_231deg_-9.9C_0023.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-045033_231deg_-10.0C_0024.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-045235_231deg_-9.9C_0025.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/lights/Light_FOV_60.stackinfo.txt
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/test_00001.fit
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/Autosave.tif
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/Autosave001.tif
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/Autosave002.tif
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3850.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3850.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3853.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3853.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3854.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3854.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3855.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3855.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3855.stackinfo.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3856.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3856.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3857.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3857.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3858.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3858.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3859.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3859.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3860.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3860.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3861.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3861.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3862.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3862.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3863.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3863.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3864.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3864.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3865.CR3
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/_MG_3865.info.txt
sessions/C2025_R3_C2025_R3_Panstarrs_Wide/2026-04-18/lights/lights.dssfilelist
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-205834_-20.0C_0001.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-210034_-20.0C_0002.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-210254_-20.0C_0003.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-210455_-20.0C_0004.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-210715_-19.9C_0005.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-210915_-20.0C_0006.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-211126_-20.0C_0007.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-211327_-20.0C_0008.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-211538_-20.0C_0009.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-211739_-20.0C_0010.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-211953_-20.0C_0011.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-212153_-19.9C_0012.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-212402_-20.0C_0013.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-212603_-20.0C_0014.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-212827_-20.0C_0015.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-213028_-20.0C_0016.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-213240_-20.0C_0017.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-213441_-20.0C_0018.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-213701_-20.0C_0019.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-213902_-19.9C_0020.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-214121_-20.0C_0021.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-214322_-20.0C_0022.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-214535_-20.0C_0023.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-214736_-20.0C_0024.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-214945_-19.9C_0025.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-215145_-20.0C_0026.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-215402_-20.0C_0027.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-215603_-20.0C_0028.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-215825_-20.0C_0029.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-220026_-20.0C_0030.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-220244_-20.0C_0031.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-220445_-20.0C_0032.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-220659_-19.9C_0033.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-220859_-20.0C_0034.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-221106_-19.9C_0035.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-221304_-19.9C_0036.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-221522_-20.0C_0037.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-221937_-20.0C_0038.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-222146_-20.0C_0039.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-222347_-20.0C_0040.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-222600_-20.0C_0041.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-222801_-20.0C_0042.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-223011_-20.0C_0043.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-224246_-16.8C_0001.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-224447_-20.6C_0002.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-224652_-19.8C_0003.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-224853_-20.0C_0004.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-225100_-20.0C_0005.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-225301_-20.0C_0006.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-225520_-20.0C_0007.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-225721_-20.0C_0008.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-225936_-20.0C_0009.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-230137_-20.0C_0010.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-230349_-20.0C_0011.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-230551_-20.0C_0012.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-230757_-20.0C_0013.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-230958_-20.0C_0014.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-231205_-19.8C_0015.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/lights/Light_Sadr_120.0s_Bin1_2600MC_gain100_20251227-231413_-20.0C_0016.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-200713_-20.0C_0001.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-200913_-20.0C_0002.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-201128_-20.0C_0003.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-201329_-20.0C_0004.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-201543_-19.9C_0005.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-201744_-20.0C_0006.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-201959_-20.0C_0007.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-202200_-20.0C_0008.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-202416_-20.0C_0009.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-202617_-20.0C_0010.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-202834_-20.0C_0011.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-203034_-20.1C_0012.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-203241_-20.0C_0013.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-203441_-20.0C_0014.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-203648_-20.0C_0015.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-203848_-20.0C_0016.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-204059_-20.0C_0017.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-204259_-20.0C_0018.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-204508_-20.0C_0019.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-204709_-20.0C_0020.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-204915_-20.0C_0021.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-205116_-20.0C_0022.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-205332_-20.0C_0023.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-205532_-20.0C_0024.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-205749_-20.0C_0025.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-205950_-20.0C_0026.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-210200_-20.0C_0027.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-210401_-20.0C_0028.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-210613_-20.0C_0029.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-210814_-20.0C_0030.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-211027_-20.0C_0031.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-211228_-20.0C_0032.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-211437_-20.0C_0033.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-211638_-19.9C_0034.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-211859_-20.0C_0035.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-212059_-20.0C_0036.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-212311_-20.0C_0037.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-212512_-20.0C_0038.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-214108_-20.0C_0001.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-214309_-20.0C_0002.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-214522_-20.0C_0003.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-214722_-20.0C_0004.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-214944_-20.0C_0005.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-215145_-20.0C_0006.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-215355_-20.0C_0007.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-215556_-20.1C_0008.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-215818_-19.9C_0009.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-220019_-20.0C_0010.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-220248_-20.0C_0011.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-220449_-20.0C_0012.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-220706_-20.0C_0013.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-220907_-20.0C_0014.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-221127_-20.0C_0015.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-221327_-20.0C_0016.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-221534_-20.0C_0017.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-30/lights/Light_Hearth_3deg_120.0s_Bin1_2600MC_gain100_20251230-221734_-20.0C_0018.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-222547_-20.1C_0002.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-222643_-20.1C_0003.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-222714_-20.1C_0004.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-222845_-20.1C_0005.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-222916_-20.0C_0006.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223011_-20.0C_0007.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223041_-20.0C_0008.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223131_-20.0C_0009.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223202_-20.0C_0010.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223300_-20.0C_0011.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223331_-20.0C_0012.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223415_-20.0C_0013.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223446_-20.0C_0014.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223531_-20.0C_0015.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223602_-20.0C_0016.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223649_-20.0C_0017.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223719_-20.0C_0018.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223756_-20.0C_0019.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223827_-20.0C_0020.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223911_-20.0C_0021.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-223942_-20.0C_0022.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-224025_-20.0C_0023.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-224056_-20.0C_0024.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-224147_-20.0C_0025.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-224218_-20.0C_0026.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-224259_-20.0C_0027.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-224330_-20.0C_0028.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-224416_-20.0C_0029.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-224447_-20.0C_0030.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_1deg_30.0s_Bin1_2600MC_gain100_20251230-224530_-20.0C_0031.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2025-12-31/lights/Light_Hearth_3deg_30.0s_Bin1_2600MC_gain100_20251230-222517_-20.1C_0001.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-192707_-9.9C_0001.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193123_-10.0C_0003.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193323_-10.0C_0004.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193533_-10.0C_0005.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193734_-9.9C_0006.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193944_-10.0C_0007.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-194145_-10.0C_0008.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_187deg_120.0s_Bin1_2600MC_gain100_20260117-192907_-10.0C_0002.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_120.0s_Bin1_2600MC_gain100_20260809-004916_86deg_-10.0C_0027.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_120.0s_Bin1_2600MC_gain100_20260809-005117_86deg_-10.0C_0028.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_120.0s_Bin1_2600MC_gain100_20260809-005330_86deg_-10.0C_0029.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-223423_86deg_-10.0C_0001.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-223924_86deg_-10.0C_0002.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-224446_86deg_-10.0C_0003.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-224947_86deg_-10.1C_0004.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-225503_86deg_-10.0C_0005.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-230003_86deg_-10.0C_0006.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-230525_86deg_-10.0C_0007.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-231026_86deg_-10.0C_0008.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-231546_86deg_-10.0C_0009.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-232047_86deg_-10.0C_0010.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-234147_86deg_-10.0C_0014.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-234718_86deg_-10.0C_0015.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-235219_86deg_-10.0C_0016.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260808-235733_86deg_-10.0C_0017.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-000235_86deg_-10.0C_0018.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-000750_86deg_-10.0C_0019.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-001251_86deg_-10.0C_0020.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-001813_86deg_-9.9C_0021.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-002314_86deg_-10.0C_0022.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-002826_86deg_-10.0C_0023.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-003327_86deg_-9.9C_0024.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-005847_86deg_-10.1C_0030.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-010347_86deg_-10.0C_0031.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-010908_86deg_-10.0C_0032.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-011409_86deg_-10.0C_0033.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-011920_86deg_-10.0C_0034.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-012456_86deg_-10.0C_0035.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-014340_265deg_-9.9C_0001.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-014951_266deg_-10.0C_0001.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-015452_266deg_-9.9C_0002.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-020017_266deg_-10.0C_0003.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-020852_266deg_-10.0C_0004.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-021353_266deg_-10.0C_0005.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-021914_266deg_-9.9C_0006.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-022415_266deg_-10.0C_0007.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-022926_266deg_-10.0C_0008.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-023427_266deg_-9.9C_0009.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-023942_266deg_-9.9C_0010.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-024443_266deg_-10.0C_0011.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-025005_266deg_-9.9C_0012.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-025506_266deg_-10.0C_0013.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-030024_266deg_-10.0C_0014.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-030525_266deg_-10.0C_0015.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-031047_266deg_-10.0C_0016.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-031547_266deg_-10.1C_0017.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260809-032106_266deg_-10.0C_0018.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-214555_87deg_-10.0C_0001.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-214657_87deg_-10.0C_0002.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-214745_87deg_-10.0C_0003.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-214816_87deg_-10.1C_0004.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-214931_87deg_-10.0C_0005.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-215002_87deg_-10.0C_0006.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-215153_87deg_-0.5C_0007.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-215224_87deg_1.3C_0008.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-215313_87deg_-1.5C_0009.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-215448_87deg_1.7C_0010.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-215537_87deg_1.4C_0011.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-215744_87deg_3.6C_0012.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-215834_87deg_-1.0C_0013.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-215938_87deg_-7.3C_0014.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-220040_87deg_-10.6C_0015.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-220113_86deg_-11.1C_0016.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-220424_87deg_1.1C_0017.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-221540_86deg_-5.8C_0001.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-221611_86deg_-7.5C_0002.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-221652_86deg_-9.6C_0003.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-221723_86deg_-10.5C_0004.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-221811_86deg_-10.4C_0005.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-221842_86deg_-10.1C_0006.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-221934_86deg_-10.0C_0007.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-222005_86deg_-9.9C_0008.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-222057_86deg_-9.9C_0009.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-222128_86deg_-10.0C_0010.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-222214_86deg_-10.0C_0011.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-222246_86deg_-10.0C_0012.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-222326_86deg_-10.0C_0013.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-222357_86deg_-10.0C_0014.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights_osc/Light_Mu Cephei_30.0s_Bin1_2600MC_gain100_20260808-222439_86deg_-10.0C_0015.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-212420_85deg_-10.0C_0003.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-212920_85deg_-9.9C_0004.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-213431_85deg_-10.0C_0005.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-213933_85deg_-10.0C_0006.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-214439_85deg_-10.0C_0007.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-214940_85deg_-10.0C_0008.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-215451_85deg_-10.0C_0009.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-215952_85deg_-10.0C_0010.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-220505_85deg_-10.0C_0011.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-221006_85deg_-9.9C_0012.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-221517_85deg_-9.8C_0013.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-222018_85deg_-9.8C_0014.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-222531_85deg_-10.0C_0015.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-223032_85deg_-10.1C_0016.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-223553_85deg_-10.0C_0017.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-224053_85deg_-10.0C_0018.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-224603_85deg_-10.0C_0019.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-225103_85deg_-10.0C_0020.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-225617_85deg_-10.0C_0021.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-230118_85deg_-10.0C_0022.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-231142_85deg_-10.0C_0024.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-232705_85deg_-10.1C_0027.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/archive/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-211409_85deg_-10.0C_0001.fit
sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-12/captures/sv220_dual-band/lights/archive/Light_Mu Cephei_300.0s_Bin1_2600MC_gain100_20260812-211910_85deg_-10.1C_0002.fit
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5676.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5677.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5678.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5679.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5680.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5681.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5682.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5683.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5684.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5685.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5686.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5687.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5688.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5689.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5691.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5692.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5693.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5694.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5696.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5697.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5698.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5699.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5700.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5701.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5702.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5703.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5704.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5705.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5706.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5707.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5708.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5709.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5710.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5711.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5712.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5713.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5714.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5715.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5716.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5717.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5718.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5719.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5720.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5721.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5722.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5723.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5724.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5725.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5726.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5727.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5728.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5729.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5730.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5731.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5732.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5733.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5734.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5735.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5736.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5737.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5738.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5739.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5740.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5741.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5742.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5743.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5744.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5745.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5746.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24-2/lights/_MG_5747.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5448.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5449.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5450.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5451.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5452.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5453.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5454.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5455.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5456.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5457.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5458.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5459.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5460.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5461.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5462.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5463.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5464.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5465.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5466.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5467.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5468.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5469.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5470.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5471.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5472.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5473.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5474.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5475.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5476.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5477.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5478.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5479.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5480.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5481.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5482.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5483.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5484.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5485.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5486.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5487.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5488.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5489.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5490.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5491.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5492.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5493.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5494.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5495.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5496.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5497.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5498.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5499.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5500.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5501.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5502.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5503.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5504.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5505.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5506.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5507.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5508.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5509.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5510.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5511.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5512.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5513.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5514.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5515.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5516.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5517.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5518.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5519.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5520.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5521.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5522.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5523.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5524.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5525.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5526.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5527.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5528.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5529.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5530.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5531.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5532.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5533.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5534.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5535.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5536.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5537.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5538.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5539.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5540.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5541.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5542.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5543.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5544.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5545.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5546.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5547.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5548.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5549.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5550.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5551.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5552.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5553.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5554.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5555.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5556.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5557.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5558.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5559.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5560.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5561.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5562.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5563.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5564.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5565.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5566.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5567.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5568.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5569.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5570.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5571.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5572.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5573.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5574.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5575.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5576.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5577.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5578.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5579.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5580.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5581.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5582.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5583.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5584.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5585.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5586.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5587.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5588.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5589.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5590.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5591.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5592.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5593.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5594.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5595.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5596.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5597.CR3
sessions/IC_4604_Rho_Ophiuchi/2026-05-24/lights/_MG_5598.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_1.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_10.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_100.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_101.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_102.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_103.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_104.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_105.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_106.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_107.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_11.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_12.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_13.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_14.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_15.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_16.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_17.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_18.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_19.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_2.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_20.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_21.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_22.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_23.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_24.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_25.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_26.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_27.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_28.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_29.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_3.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_30.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_31.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_32.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_33.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_34.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_35.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_36.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_37.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_38.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_39.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_4.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_40.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_41.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_42.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_43.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_44.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_45.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_46.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_47.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_48.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_49.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_5.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_50.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_51.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_52.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_53.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_54.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_55.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_56.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_57.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_58.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_59.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_6.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_60.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_61.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_62.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_63.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_64.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_65.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_66.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_67.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_68.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_69.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_7.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_70.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_71.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_72.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_73.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_74.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_75.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_76.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_77.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_78.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_79.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_8.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_80.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_81.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_82.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_83.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_84.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_85.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_86.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_87.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_88.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_89.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_9.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_90.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_91.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_92.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_93.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_94.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_95.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_96.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_97.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_98.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/Lightroom Export/Seq_99.tif
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3211.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3212.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3213.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3214.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3215.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3216.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3217.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3218.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3219.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3220.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3221.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3222.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3223.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3224.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3225.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3226.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3227.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3228.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3229.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3230.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3231.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3232.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3233.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3234.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3235.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3236.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3237.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3238.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3239.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3240.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3241.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3242.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3243.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3244.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3245.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3246.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3247.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3248.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3249.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3250.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3251.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3252.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3253.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3254.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3255.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3256.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3257.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3258.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3259.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3260.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3261.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3262.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3263.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3264.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3265.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3266.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3268.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3269.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3270.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3271.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3272.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3273.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3274.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3275.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3276.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3277.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3278.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3279.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3281.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3282.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3283.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3284.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3285.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3286.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3287.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3288.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3289.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3290.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3291.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3292.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3293.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3294.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3295.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3296.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3297.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3298.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3299.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3300.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3302.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3303.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3304.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3305.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3306.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3307.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3308.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3309.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3310.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3311.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3312.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3313.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3316.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3317.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3318.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3319.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3320.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3321.CR3
sessions/M42_M45_Orion_and_Pleiades_Timelapse/2026-04-05/lights/_MG_3322.CR3
sessions/M42_Orion/2026-01-17/FOV______123x60sec_7380s_2026-01-19_2033_og.fit
sessions/M42_Orion/2026-01-17/FOV______136x60sec_8160s_2026-01-22_2045_og.fit
sessions/M42_Orion/2026-01-17/FOV______136x60sec_8160s_2026-01-22_2045_og_pixisgnist.fit
sessions/M42_Orion/2026-01-17/FOV______136x60sec_8160s_2026-01-22_2045_og_process.fit
sessions/M42_Orion/2026-01-17/FOV______136x60sec_8160s_2026-01-22_2045_og_process_spcc_bgextract.fit
sessions/M42_Orion/2026-01-17/FOV______160x60sec_9600s__drizzle-1-5x_2026-01-22_1625_og.fit
sessions/M42_Orion/2026-01-17/FOV______160x60sec_9600s__drizzle-1-5x_2026-01-22_1625_og_og.fit
sessions/M42_Orion/2026-01-17/FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process.fit
sessions/M42_Orion/2026-01-17/FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_2.fit
sessions/M42_Orion/2026-01-17/FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_test.fit
sessions/M42_Orion/2026-01-17/lights/FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-230623_-10.4C_0001.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-230723_-9.6C_0002.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-230857_-9.9C_0003.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-230958_-10.1C_0004.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-231117_-10.1C_0005.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-231218_-10.3C_0006.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-231404_-9.8C_0007.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-231505_-10.2C_0008.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-231617_-9.3C_0009.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-231718_-9.8C_0010.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-231832_-9.8C_0011.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-231933_-10.1C_0012.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-232119_-10.0C_0013.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-232220_-9.7C_0014.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-232356_-9.7C_0015.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-232456_-9.6C_0016.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-232622_-10.3C_0017.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-232724_-10.2C_0018.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-232904_-10.3C_0019.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-233005_-9.8C_0020.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-233135_-9.8C_0021.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-233236_-9.8C_0022.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-233404_-10.4C_0023.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-233504_-9.6C_0024.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-233617_-10.1C_0025.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-233718_-9.4C_0026.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-233854_-10.1C_0027.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-233954_-10.0C_0028.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-234109_-10.0C_0029.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-234210_-10.0C_0030.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-234328_-10.1C_0031.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-234429_-9.5C_0032.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-234608_-9.9C_0033.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-234708_-10.2C_0034.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-234827_-10.3C_0035.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-234928_-9.8C_0036.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-235118_-10.4C_0037.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-235219_-9.6C_0038.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-235330_-10.1C_0039.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-235431_-9.8C_0040.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-235550_-9.9C_0041.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-235651_-10.4C_0042.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-235802_-10.2C_0043.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260117-235903_-9.8C_0044.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260118-000104_-9.5C_0045.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260118-000204_-10.0C_0046.fit
sessions/M42_Orion/2026-01-17/lights/Light_FOV_63deg_60.0s_Bin1_2600MC_gain100_20260118-000318_-10.2C_0047.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-201730_-10.1C_0001.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-201831_-10.0C_0002.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-201939_-10.0C_0003.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-202040_-10.1C_0004.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-202154_-9.9C_0005.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-202255_-10.1C_0006.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-202413_-10.1C_0007.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-202514_-10.0C_0008.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-202627_-10.0C_0009.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-202727_-9.8C_0010.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-202841_-10.0C_0011.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-202942_-10.1C_0012.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-203053_-10.1C_0013.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-203154_-9.7C_0014.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-203311_-10.3C_0015.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-203412_-10.0C_0016.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-203532_-9.7C_0017.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-203633_-10.3C_0018.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-203805_-10.3C_0019.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-203907_-10.0C_0020.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-204019_-10.2C_0021.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-204120_-10.3C_0022.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-204233_-10.1C_0023.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-204334_-10.3C_0024.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-204451_-10.3C_0025.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-204552_-10.0C_0026.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-204727_-10.3C_0027.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-204828_-10.0C_0028.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-204947_-10.2C_0029.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-205048_-10.1C_0030.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-205215_-9.8C_0031.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-205316_-9.4C_0032.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-205432_-10.3C_0033.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-205533_-10.0C_0034.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-205658_-10.1C_0035.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-205759_-10.3C_0036.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-205912_-10.3C_0037.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-210013_-10.2C_0038.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-210131_-10.1C_0039.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-210232_-9.5C_0040.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-210357_-9.5C_0041.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-210458_-10.4C_0042.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-210631_-10.0C_0043.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-210732_-9.6C_0044.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-210847_-10.3C_0045.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-210948_-10.3C_0046.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-211100_-10.2C_0047.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-211201_-9.7C_0048.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-211313_-9.6C_0049.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-211414_-10.3C_0050.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-211530_-10.3C_0051.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-211631_-9.8C_0052.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-211819_-10.0C_0053.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-211920_-9.6C_0054.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-212049_-10.3C_0055.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-212150_-10.1C_0056.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-212321_-10.1C_0057.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-212422_-9.9C_0058.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-212547_-9.5C_0059.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-212648_-10.1C_0060.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-212802_-10.1C_0061.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-212903_-9.9C_0062.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-213014_-10.0C_0063.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-213115_-10.0C_0064.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-213254_-10.0C_0065.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-213355_-10.0C_0066.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-213515_-9.9C_0067.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-213617_-10.0C_0068.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-213728_-10.0C_0069.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-213829_-10.0C_0070.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-213941_-10.0C_0071.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-214042_-10.0C_0072.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-214220_-10.1C_0073.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-214321_-9.9C_0074.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-214434_-10.0C_0075.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-214534_-10.0C_0076.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-214657_-10.0C_0077.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-214758_-10.0C_0078.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-214914_-10.0C_0079.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-215015_-10.0C_0080.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-215129_-10.0C_0081.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-215230_-10.1C_0082.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-215403_-10.1C_0083.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-215504_-10.1C_0084.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-215615_-10.3C_0085.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-215716_-10.0C_0086.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-215834_-9.5C_0087.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-215934_-9.8C_0088.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-220042_-10.3C_0089.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-220143_-10.1C_0090.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-220258_-9.9C_0091.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-220359_-10.3C_0092.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-220515_-10.3C_0093.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-220616_-9.9C_0094.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-220730_-10.0C_0095.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-220830_-9.9C_0096.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-220942_-10.1C_0097.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-221043_-10.0C_0098.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-221157_-10.2C_0099.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-221258_-10.1C_0100.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-221415_-10.3C_0101.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-221516_-10.2C_0102.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-221628_-10.0C_0103.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-221728_-10.4C_0104.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-221840_-10.3C_0105.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-221941_-10.0C_0106.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-222056_-10.3C_0107.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-222157_-10.3C_0108.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-222316_-9.6C_0109.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-222417_-9.7C_0110.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-222535_-10.3C_0111.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-222636_-10.4C_0112.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-222753_-10.1C_0113.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-222854_-10.3C_0114.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-223018_-10.1C_0115.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-223119_-10.4C_0116.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-223240_-10.3C_0117.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-223341_-10.1C_0118.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-223457_-10.2C_0119.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-223558_-10.4C_0120.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-223759_-10.3C_0121.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-223900_-9.8C_0122.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-224101_-10.3C_0123.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-224202_-9.8C_0124.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-224404_-10.1C_0125.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-224505_-10.3C_0126.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-224706_-9.7C_0127.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-224807_-10.1C_0128.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-225009_-9.5C_0129.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-225110_-9.6C_0130.fit
sessions/M42_Orion/2026-01-17/lights/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-225311_-10.4C_0131.fit
sessions/M42_Orion/2026-01-17/lights/masters/session1_6s_2026-01-17_-9.6C_flats_stacked.fit
sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process.fit
sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_strechy.fit
sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_strechy_2.fit
sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_strechy_overstreched.fit
sessions/M42_Orion/2026-01-17/lights/starless_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_strechy_veraluxú.fit
sessions/M42_Orion/2026-01-17/lights/starmask_FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process.fit
sessions/M42_Orion/2026-01-17/lights/wide/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-200623_-9.9C_0001.fit
sessions/M42_Orion/2026-01-17/lights/wide/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-200724_-10.0C_0002.fit
sessions/M42_Orion/2026-01-17/lights/wide/Light_M 42_245deg_60.0s_Bin1_2600MC_gain100_20260117-200836_-10.0C_0003.fit
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3124.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3125.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3126.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3127.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3128.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3129.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3130.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3131.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3132.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3133.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3134.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3135.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3136.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3137.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3139.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3140.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3141.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3142.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3143.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3144.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3145.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3146.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3147.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3148.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3149.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3150.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3151.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3152.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3153.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3154.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3155.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3156.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3157.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3158.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3159.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3160.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3161.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3162.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3163.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3164.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3165.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3166.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3167.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3168.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3169.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3170.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3171.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3172.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3173.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3174.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3175.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3176.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3177.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3178.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3179.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3180.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3181.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3182.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3183.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3184.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3185.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3186.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3187.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3188.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3189.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3190.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3191.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3192.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3193.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3194.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3195.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3196.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3197.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3198.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3199.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3200.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3201.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3202.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3203.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3204.CR3
sessions/M42_Orion_Wide_Field_70MM/2026-04-06/lights/_MG_3205.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0683.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0683.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0684.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0684.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0685.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0685.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0686.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0686.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0687.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0687.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0688.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0688.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0689.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0689.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0690.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0690.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0691.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0691.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0692.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0692.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0693.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0693.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0694.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0694.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0695.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0695.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0696.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0696.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0697.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0697.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0698.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0698.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0699.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0699.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0700.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0700.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0701.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0701.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0702.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0702.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0703.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0703.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0704.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0704.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0705.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0705.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0706.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0706.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0707.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0707.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0708.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0708.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0709.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0709.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0710.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0710.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0711.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0711.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0712.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0712.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0713.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0713.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0714.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0714.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0715.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0715.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0716.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0716.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0717.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0717.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0718.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0718.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0719.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0719.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0720.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0720.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0721.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0721.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0722.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0722.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0723.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0723.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0724.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0724.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0725.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0725.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0726.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0726.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0727.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0727.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0728.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0728.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0729.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0729.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0730.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0730.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0731.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0731.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0732.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0732.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0733.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0733.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0734.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0734.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0735.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0735.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0736.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0736.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0737.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0737.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0738.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0738.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0739.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0739.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0740.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0740.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0741.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0741.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0742.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0742.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0743.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0743.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0744.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0744.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0745.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0745.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0746.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0746.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0747.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0747.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0748.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0748.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0749.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0749.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0750.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0750.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0751.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0751.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0752.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0752.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0753.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0753.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0754.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0754.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0755.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0755.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0756.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0756.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0757.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0757.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0758.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0758.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0759.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0759.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0760.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0760.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0761.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0761.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0762.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0762.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0763.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0763.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0764.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0764.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0765.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0765.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0766.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0766.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0767.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0767.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0768.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0768.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0769.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0769.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0770.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0770.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0771.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0771.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0772.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0772.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0773.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0773.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0774.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0774.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0775.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0775.xmp
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0776.CR3
sessions/M42_Orion_wide_field/2026-02-18/lights/_MG_0776.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2532.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2532.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2533.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2533.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2534.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2534.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2535.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2535.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2536.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2536.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2537.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2537.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2538.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2538.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2539.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2539.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2540.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2540.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2541.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2541.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2542.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2542.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2543.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2543.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2544.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2544.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2545.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2545.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2546.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2546.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2547.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2547.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2548.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2548.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2549.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2549.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2550.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2550.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2551.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2551.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2552.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2552.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2553.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2553.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2554.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2554.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2555.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2555.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2556.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2556.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2557.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2557.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2558.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2558.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2559.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2559.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2560.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2560.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2561.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2561.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2562.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2562.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2563.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2563.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2564.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2564.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2565.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2565.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2566.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2566.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2567.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2567.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2568.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2568.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2569.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2569.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2570.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2570.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2571.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2571.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2572.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2572.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2573.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2573.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2574.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2574.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2575.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2575.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2576.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2576.xmp
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2577.CR3
sessions/M42_Orion_wide_field/2026-03-15/lights/_MG_2577.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2370.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2370.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2371.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2371.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2372.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2372.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2373.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2373.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2374.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2374.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2375.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2375.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2376.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2376.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2377.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2377.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2378.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2378.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2379.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2379.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2380.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2380.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2381.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2381.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2382.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2382.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2383.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2383.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2384.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2384.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2385.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2385.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2386.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2386.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2387.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2387.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2388.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2388.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2389.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2389.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2390.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2390.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2391.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2391.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2392.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2392.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2393.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2393.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2394.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2394.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2395.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2395.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2396.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2396.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2397.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2397.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2398.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2398.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2399.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2399.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2400.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2400.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2401.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2401.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2402.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2402.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2403.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2403.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2404.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2404.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2405.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2405.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2406.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2406.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2407.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2407.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2409.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2409.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2411.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2411.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2412.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2412.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2413.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2413.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2415.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2415.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2416.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2416.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2417.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2417.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2418.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2418.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2419.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2419.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2420.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2420.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2421.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2421.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2422.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2422.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2423.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2423.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2424.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2424.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2425.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2425.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2426.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2426.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2427.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2427.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2428.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2428.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2429.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2429.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2430.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2430.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2431.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2431.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2432.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2432.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2433.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2433.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2434.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2434.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2435.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2435.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2436.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2436.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2437.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2437.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2438.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2438.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2439.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2439.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2440.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2440.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2441.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2441.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2442.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2442.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2443.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2443.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2444.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2444.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2445.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2445.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2446.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2446.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2447.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2447.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2448.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2448.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2449.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2449.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2450.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2450.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2451.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2451.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2452.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2452.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2453.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2453.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2454.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2454.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2456.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2456.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2457.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2457.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2458.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2458.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2459.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2459.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2460.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2460.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2461.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2461.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2462.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2462.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2463.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2463.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2464.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2464.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2465.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2465.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2466.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2466.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2467.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2467.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2468.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2468.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2469.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2469.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2470.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2470.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2471.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2471.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2472.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2472.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2473.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2473.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2474.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2474.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2475.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2475.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2476.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2476.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2477.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2477.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2478.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2478.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2479.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2479.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2481.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2481.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2482.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2482.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2483.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2483.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2484.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2484.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2485.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2485.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2486.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2486.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2487.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2487.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2488.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2488.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2489.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2489.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2490.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2490.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2491.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2491.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2492.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2492.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2493.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2493.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2494.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2494.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2495.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2495.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2496.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2496.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2497.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2497.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2498.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2498.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2499.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2499.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2500.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2500.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2501.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2501.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2502.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2502.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2503.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2503.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2504.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2504.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2505.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2505.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2506.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2506.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2507.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2507.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2508.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2508.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2509.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2509.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2510.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2510.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2511.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2511.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2512.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2512.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2513.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2513.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2514.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2514.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2515.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2515.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2516.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2516.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2517.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2517.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2518.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2518.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2519.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2519.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2520.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2520.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2521.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2521.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2522.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2522.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2523.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2523.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2524.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2524.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2525.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2525.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2526.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2526.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2528.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2528.xmp
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2530.CR3
sessions/M42_Orion_wide_field/2026-03-15_hibas/lights/_MG_2530.xmp
sessions/M84_Markarians_Chain/2026-04-18/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1459_og.fit
sessions/M84_Markarians_Chain/2026-04-18/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1502_og.fit
sessions/M84_Markarians_Chain/2026-04-18/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1507_og.fit
sessions/M84_Markarians_Chain/2026-04-18/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1511_og.fit
sessions/M84_Markarians_Chain/2026-04-18/individual_stacks/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1511_session1.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Autosave.tif
sessions/M84_Markarians_Chain/2026-04-18/lights/Autosave001.tif
sessions/M84_Markarians_Chain/2026-04-18/lights/Autosave002.tif
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-020412_356deg_-10.0C_0002.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-020412_356deg_-10.0C_0002.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-020732_356deg_-10.1C_0003.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-020732_356deg_-10.1C_0003.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-021033_356deg_-10.0C_0004.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-021033_356deg_-10.0C_0004.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-022055_356deg_-10.2C_0006.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-022055_356deg_-10.2C_0006.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-022055_356deg_-10.2C_0006.stackinfo.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-022411_356deg_-10.0C_0007.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-022411_356deg_-10.0C_0007.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-022711_356deg_-10.0C_0008.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-022711_356deg_-10.0C_0008.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-023029_356deg_-10.0C_0009.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-023029_356deg_-10.0C_0009.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-023330_356deg_-10.0C_0010.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-023330_356deg_-10.0C_0010.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-023653_356deg_-10.0C_0011.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-023653_356deg_-10.0C_0011.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-023954_356deg_-10.0C_0012.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-023954_356deg_-10.0C_0012.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-024308_356deg_-10.0C_0013.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-024308_356deg_-10.0C_0013.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-024925_356deg_-10.0C_0015.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-024925_356deg_-10.0C_0015.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-025227_356deg_-10.0C_0016.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-025227_356deg_-10.0C_0016.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-025547_356deg_-10.0C_0017.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-025547_356deg_-10.0C_0017.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-025848_356deg_-10.0C_0018.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-025848_356deg_-10.0C_0018.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-030500_356deg_-10.0C_0020.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-030500_356deg_-10.0C_0020.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-030812_356deg_-10.1C_0021.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-030812_356deg_-10.1C_0021.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-031427_356deg_-10.1C_0023.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-031427_356deg_-10.1C_0023.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-031728_356deg_-10.0C_0024.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-031728_356deg_-10.0C_0024.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-032344_356deg_-10.0C_0026.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-032344_356deg_-10.0C_0026.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-032656_356deg_-10.0C_0027.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-032656_356deg_-10.0C_0027.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-033307_356deg_-10.0C_0028.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-033307_356deg_-10.0C_0028.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-033618_356deg_-10.0C_0029.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-033618_356deg_-10.0C_0029.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-033919_356deg_-10.0C_0030.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-033919_356deg_-10.0C_0030.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-034236_356deg_-10.0C_0031.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-034236_356deg_-10.0C_0031.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-034537_356deg_-10.0C_0032.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-034537_356deg_-10.0C_0032.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-034853_356deg_-10.0C_0033.fit
sessions/M84_Markarians_Chain/2026-04-18/lights/Light_Markarians Chain_180.0s_Bin1_2600MC_gain100_20260418-034853_356deg_-10.0C_0033.info.txt
sessions/M84_Markarians_Chain/2026-04-18/lights/lights.dssfilelist
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3805.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3805.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3806.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3806.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3807.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3807.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3808.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3808.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3809.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3809.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3810.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3810.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3811.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3811.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3812.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3812.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3813.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3813.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3814.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3814.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3815.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3815.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3816.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3816.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3817.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3817.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3818.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3818.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3819.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3819.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3820.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3820.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3821.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3821.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3822.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3822.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3823.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3823.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3824.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3824.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3825.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3825.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3826.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3826.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3827.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3827.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3828.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3828.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3829.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3829.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3830.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3830.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3831.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3831.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3832.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3832.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3833.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3833.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3834.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3834.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3835.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3835.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3836.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3836.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3837.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3837.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3838.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3838.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3839.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3839.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3840.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3840.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3841.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3841.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3842.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame1/_MG_3842.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3744.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3744.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3745.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3745.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3746.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3746.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3747.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3747.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3748.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3748.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3749.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3749.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3750.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3750.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3751.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3751.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3752.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3752.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3753.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3753.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3754.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3754.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3755.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3755.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3756.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3756.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3757.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3757.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3758.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3758.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3759.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3759.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3760.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3760.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3761.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3761.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3762.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3762.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3763.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3763.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3764.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3764.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3765.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3765.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3766.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3766.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3767.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3767.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3768.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3768.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3769.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3769.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3770.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3770.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3771.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3771.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3772.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3772.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3773.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3773.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3774.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3774.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3775.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3775.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3776.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3776.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3777.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3777.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3778.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3778.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3779.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3779.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3780.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3780.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3781.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3781.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3782.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3782.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3783.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3783.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3784.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3784.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3785.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3785.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3786.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3786.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3787.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3787.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3788.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3788.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3789.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3789.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3790.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3790.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3791.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3791.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3792.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3792.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3793.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3793.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3794.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3794.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3795.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3795.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3796.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3796.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3797.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3797.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3798.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3798.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3799.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3799.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3800.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3800.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3801.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3801.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3802.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3802.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3803.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3803.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3804.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame2/_MG_3804.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3720.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3720.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3721.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3721.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3722.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3722.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3723.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3723.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3724.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3724.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3725.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3725.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3726.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3726.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3727.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3727.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3728.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3728.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3729.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3729.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3730.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3730.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3731.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3731.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3732.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3732.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3733.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3733.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3734.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3734.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3735.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3735.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3736.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3736.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3737.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3737.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3738.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3738.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3739.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3739.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3740.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3740.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3741.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3741.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3742.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3742.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3743.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame3/_MG_3743.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3689.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3689.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3697.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3697.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3698.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3698.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3700.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3700.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3701.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3701.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3702.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3702.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3703.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3703.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3704.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3704.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3705.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3705.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3706.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3706.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3707.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3707.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3708.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3708.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3709.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3709.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3710.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3710.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3711.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3711.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3712.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3712.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3713.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3713.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3714.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3714.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3715.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3715.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3716.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame4/_MG_3716.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3628.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3628.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3629.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3629.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3630.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3630.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3631.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3631.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3632.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3632.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3633.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3633.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3634.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3634.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3635.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3635.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3636.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3636.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3637.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3637.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3638.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3638.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3639.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3639.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3641.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3641.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3642.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3642.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3643.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3643.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3644.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3644.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3645.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3645.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3646.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3646.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3647.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3647.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3648.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3648.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3649.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3649.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3650.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3650.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3651.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3651.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3652.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3652.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3653.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3653.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3654.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3654.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3655.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3655.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3656.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3656.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3657.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3657.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3658.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3658.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3659.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3659.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3660.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3660.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3661.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3661.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3662.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3662.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3663.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3663.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3664.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3664.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3665.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3665.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3666.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3666.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3667.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3667.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3668.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3668.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3669.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3669.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3670.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3670.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3671.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3671.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3672.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3672.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3673.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3673.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3674.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3674.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3675.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3675.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3676.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3676.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3677.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3677.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3678.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3678.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3679.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3679.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3680.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3680.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3681.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3681.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3682.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3682.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3683.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3683.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3684.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3684.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3685.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3685.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3686.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3686.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3687.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame5/_MG_3687.tif
sessions/M_Milky_Way/2026-04-18/lights/Frame6/_MG_3627.CR3
sessions/M_Milky_Way/2026-04-18/lights/Frame6/_MG_3627.tif
sessions/M_Milky_Way/2026-04-19/lights/Autosave.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Autosave.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame1/_MG_3889.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame1/_MG_3890.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame1/_MG_3891.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame2/_MG_3893.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame2/_MG_3894.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame2/_MG_3895.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame3/_MG_3896.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame3/_MG_3897.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame3/_MG_3898.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame4/_MG_3900.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame4/_MG_3902.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame4/_MG_3903.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame4/_MG_3904.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame5/_MG_3905.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame5/_MG_3906.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame5/_MG_3907.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame5/_MG_3908.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame5/_MG_3909.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame5/_MG_3910.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame6/_MG_3911.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame6/_MG_3912.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame6/_MG_3913.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame7/_MG_3914.tif
sessions/M_Milky_Way/2026-04-19/lights/TIFF/Frame7/_MG_3915.tif
sessions/M_Milky_Way/2026-04-19/lights/_MG_3889.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3889.xmp
sessions/M_Milky_Way/2026-04-19/lights/_MG_3890.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3891.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3893.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3894.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3895.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3896.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3897.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3898.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3900.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3902.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3903.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3904.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3905.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3906.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3907.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3908.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3909.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3910.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3911.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3912.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3913.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3914.CR3
sessions/M_Milky_Way/2026-04-19/lights/_MG_3915.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/Generated_OSC_Widefield_Astrometric_Distortion.ssf
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7829.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7829.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7831.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7831.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7832.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7832.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7833.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7833.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7834.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7834.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7835.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7835.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7836.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7836.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7837.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7837.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7838.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7838.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7839.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7839.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7840.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7840.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7841.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7841.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7842.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7842.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7843.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7843.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7844.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7844.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7845.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7845.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7846.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7846.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7847.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7847.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7848.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7848.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7849.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7849.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7850.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7850.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7851.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7851.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7852.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7852.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7853.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7853.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7854.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7854.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7855.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7855.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7856.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7856.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7857.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7857.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7858.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7858.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7859.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7859.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7860.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel1/lights/_MG_7860.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/panel1-mask.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/panel1.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel1/result.fit
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8129.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8129.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8129.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8130.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8130.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8130.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8131.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8131.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8131.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8132.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8132.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8132.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8133.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8133.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8133.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8134.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8134.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8134.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8135.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8135.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8135.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8136.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8136.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8136.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8137.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8137.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8137.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8138.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8138.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8138.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8139.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8139.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8139.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8140.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8140.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8140.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8141.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8141.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8141.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8142.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8142.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8142.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8143.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8143.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8143.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8144.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8144.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8144.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8145.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8145.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8145.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8146.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8146.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8146.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8147.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8147.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8147.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8148.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8148.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8148.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8149.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8149.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8149.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8150.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8150.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8150.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8151.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8151.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8151.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8152.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8152.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8152.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8153.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8153.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8153.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8154.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8154.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8154.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8155.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8155.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8155.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8156.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8156.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8156.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8157.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8157.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8157.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8158.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8158.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8158.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8159.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8159.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel10/_MG_8159.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8160.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8160.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8160.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8161.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8161.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8161.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8162.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8162.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8162.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8163.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8163.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8163.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8164.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8164.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8164.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8165.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8165.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8165.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8166.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8166.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8166.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8167.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8167.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8167.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8168.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8168.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8168.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8169.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8169.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8169.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8170.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8170.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8170.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8171.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8171.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8171.stackinfo.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8171.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8172.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8172.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8172.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8173.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8173.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8173.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8174.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8174.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8174.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8175.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8175.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8175.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8176.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8176.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8176.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8177.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8177.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8177.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8178.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8178.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8178.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8179.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8179.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8179.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8180.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8180.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8180.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8181.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8181.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8181.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8182.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8182.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8182.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8183.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8183.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8183.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8184.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8184.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8184.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8185.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8185.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8185.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8186.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8186.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8186.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8187.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8187.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8187.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8188.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8188.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8188.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8189.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8189.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8189.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8190.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8190.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel11/_MG_8190.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7861.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7861.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7862.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7862.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7863.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7863.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7865.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7865.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7866.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7866.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7867.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7867.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7868.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7868.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7869.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7869.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7870.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7870.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7871.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7871.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7872.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7872.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7873.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7873.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7874.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7874.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7875.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7875.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7876.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7876.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7877.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7877.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7878.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7878.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7879.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7879.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7880.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7880.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7881.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7881.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7882.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7882.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7883.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7883.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7884.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7884.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7885.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7885.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7886.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7886.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7887.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7887.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7888.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel2/_MG_7888.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7889.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7889.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7890.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7890.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7891.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7891.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7892.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7892.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7893.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7893.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7894.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7894.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7895.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7895.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7896.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7896.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7897.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7897.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7898.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7898.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7899.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7899.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7900.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7900.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7901.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7901.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7902.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7902.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7903.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7903.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7904.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7904.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7905.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7905.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7906.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7906.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7907.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7907.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7908.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7908.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7909.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7909.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7910.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7910.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7911.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7911.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7912.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7912.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7913.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7913.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7914.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7914.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7915.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7915.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7916.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7916.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7917.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7917.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7918.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel3/_MG_7918.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7919.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7919.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7920.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7920.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7922.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7922.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7923.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7923.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7924.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7924.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7925.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7925.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7926.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7926.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7927.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7927.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7928.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7928.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7929.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7929.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7930.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7930.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7931.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7931.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7932.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7932.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7933.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7933.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7934.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7934.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7935.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7935.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7936.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7936.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7939.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7939.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7940.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7940.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7941.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7941.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7942.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7942.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7943.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7943.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7944.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7944.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7945.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7945.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7946.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7946.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7947.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7947.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7948.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7948.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7949.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7949.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7950.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7950.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7951.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7951.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7952.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7952.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7953.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7953.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7954.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7954.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7955.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7955.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7956.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7956.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7957.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7957.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7958.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7958.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7959.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7959.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7960.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7960.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7961.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7961.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7962.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel4/_MG_7962.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7964.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7964.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7965.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7965.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7966.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7966.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7968.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7968.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7969.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7969.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7970.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7970.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7971.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7971.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7972.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7972.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7973.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7973.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7974.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7974.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7975.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7975.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7976.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7976.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7977.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7977.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7978.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7978.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7979.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7979.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7980.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7980.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7981.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7981.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7982.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7982.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7983.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7983.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7984.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7984.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7985.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7985.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7986.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7986.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7987.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7987.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7988.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7988.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7989.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7989.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7990.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7990.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7991.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7991.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7992.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7992.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7993.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7993.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7994.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7994.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7995.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7995.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7996.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7996.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7997.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel5/_MG_7997.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_7998.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_7998.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_7998.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_7999.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_7999.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_7999.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8000.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8000.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8000.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8001.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8001.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8001.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8002.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8002.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8002.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8003.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8003.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8003.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8004.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8004.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8004.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8005.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8005.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8005.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8006.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8006.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8006.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8007.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8007.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8007.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8008.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8008.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8008.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8009.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8009.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8009.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8010.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8010.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8010.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8011.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8011.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8011.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8012.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8012.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8012.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8013.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8013.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8013.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8014.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8014.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8014.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8015.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8015.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8015.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8016.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8016.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8016.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8017.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8017.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8017.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8018.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8018.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8018.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8019.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8019.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8019.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8020.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8020.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8020.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8021.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8021.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8021.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8022.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8022.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8022.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8023.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8023.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8023.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8024.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8024.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8024.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8025.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8025.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8025.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8026.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8026.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8026.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8027.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8027.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8027.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8028.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8028.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8028.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8029.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8029.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8029.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8030.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8030.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8030.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8031.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8031.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8031.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8032.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8032.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8033.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel6/_MG_8033.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8035.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8035.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8035.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8037.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8037.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8037.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8038.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8038.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8038.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8039.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8039.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8039.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8040.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8040.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8040.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8041.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8041.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8041.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8042.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8042.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8042.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8043.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8043.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8043.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8044.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8044.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8044.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8045.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8045.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8045.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8046.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8046.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8046.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8047.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8047.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8047.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8048.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8048.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8048.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8049.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8049.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8049.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8050.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8050.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8050.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8051.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8051.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8051.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8052.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8052.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8052.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8053.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8053.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8053.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8054.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8054.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8054.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8055.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8055.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8055.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8056.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8056.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8056.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8057.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8057.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8057.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8058.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8058.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8058.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8059.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8059.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8059.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8060.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8060.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8060.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8061.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8061.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8061.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8062.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8062.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8062.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8063.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8063.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8063.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8064.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8064.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8064.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8065.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8065.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8065.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8066.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8066.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel7/_MG_8066.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8067.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8067.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8067.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8068.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8068.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8068.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8069.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8069.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8069.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8070.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8070.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8070.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8071.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8071.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8071.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8072.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8072.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8072.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8073.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8073.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8073.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8074.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8074.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8074.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8075.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8075.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8075.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8076.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8076.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8076.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8077.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8077.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8077.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8078.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8078.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8078.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8079.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8079.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8079.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8080.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8080.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8080.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8081.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8081.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8081.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8082.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8082.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8082.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8083.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8083.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8083.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8084.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8084.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8084.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8085.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8085.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8085.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8086.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8086.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8086.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8087.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8087.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8087.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8088.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8088.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8088.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8089.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8089.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8089.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8090.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8090.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8090.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8091.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8091.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8091.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8092.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8092.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8092.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8093.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8093.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8093.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8094.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8094.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8094.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8095.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8095.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8095.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8096.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8096.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8096.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8097.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8097.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel8/_MG_8097.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8098.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8098.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8098.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8099.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8099.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8099.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8100.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8100.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8100.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8101.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8101.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8101.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8102.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8102.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8102.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8103.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8103.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8103.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8104.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8104.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8104.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8105.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8105.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8105.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8106.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8106.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8106.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8107.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8107.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8107.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8108.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8108.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8108.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8109.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8109.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8109.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8110.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8110.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8110.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8111.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8111.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8111.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8112.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8112.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8112.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8113.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8113.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8113.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8114.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8114.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8114.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8115.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8115.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8115.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8116.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8116.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8116.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8117.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8117.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8117.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8118.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8118.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8118.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8119.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8119.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8119.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8120.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8120.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8120.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8121.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8121.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8121.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8122.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8122.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8122.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8123.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8123.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8123.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8124.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8124.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8124.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8125.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8125.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8125.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8126.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8126.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8126.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8127.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8127.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8127.tif
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8128.CR3
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8128.info.txt
sessions/M_Milky_Way/2026-06-19/lights/Panel9/_MG_8128.tif
sessions/M_Milky_Way/2026-06-19/lights/panel1-mask.tif
sessions/M_Milky_Way/2026-06-19/lights/panel1.tif
sessions/M_Milky_Way/2026-06-19/lights/panel2-mask.tif
sessions/M_Milky_Way/2026-06-19/lights/panel2.tif
sessions/M_Milky_Way/2026-06-19/lights/panel4-mask.tif
sessions/M_Milky_Way/2026-06-19/lights/panel4.tif
sessions/NGC2237_Rosette_Nebula/2026-02-25/NGC_2237_085x60sec_5100s_2026-03-01_1629_og.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/NGC_2237_085x60sec_5100s_2026-03-01_1629_og_work.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-211743_-10.4C_0063.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-211844_-10.1C_0064.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-211946_-10.1C_0065.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212047_-10.1C_0066.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212202_-10.1C_0067.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212303_-10.1C_0068.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212542_-10.1C_0069.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212643_-10.1C_0070.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212804_-10.1C_0071.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212905_-10.1C_0072.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213043_-10.0C_0073.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213144_-10.0C_0074.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213342_-10.0C_0075.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213443_-10.0C_0076.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213644_-10.1C_0077.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213745_-10.0C_0078.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213943_-9.9C_0079.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214044_-10.0C_0080.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214245_-10.0C_0081.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214346_-10.0C_0082.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214525_-10.1C_0083.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214626_-10.0C_0084.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214800_-10.0C_0085.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214901_-10.0C_0086.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-215102_-10.1C_0087.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-215203_-10.0C_0088.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-194429_-10.1C_0003.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-194700_-10.0C_0005.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195044_-10.0C_0008.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195300_-10.0C_0010.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195426_-10.1C_0011.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195527_-10.2C_0012.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195725_-10.1C_0013.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195826_-10.0C_0014.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200027_-9.9C_0015.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200127_-10.0C_0016.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200328_-10.0C_0017.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200429_-10.0C_0018.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200600_-9.9C_0019.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200701_-9.8C_0020.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200829_-9.9C_0021.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200930_-10.0C_0022.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201116_-10.0C_0023.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201217_-10.0C_0024.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201336_-10.0C_0025.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201438_-10.0C_0026.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201550_-10.0C_0027.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201651_-10.0C_0028.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201840_-10.0C_0029.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201953_-10.0C_0030.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202106_-10.0C_0031.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202207_-10.0C_0032.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202325_-10.0C_0033.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202426_-10.0C_0034.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202627_-10.0C_0035.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202728_-10.0C_0036.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202929_-10.0C_0037.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203029_-10.0C_0038.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203149_-10.0C_0039.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203250_-10.0C_0040.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203414_-10.0C_0041.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203515_-10.0C_0042.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203709_-10.0C_0043.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203810_-10.0C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203924_-10.0C_0045.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204025_-10.0C_0046.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204145_-10.0C_0047.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204246_-10.0C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204404_-10.0C_0049.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204505_-10.0C_0050.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204706_-10.0C_0051.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204807_-10.0C_0052.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204938_-10.0C_0053.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205039_-10.0C_0054.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205158_-10.0C_0055.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205259_-10.1C_0056.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205500_-10.0C_0057.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205601_-10.0C_0058.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205802_-10.1C_0059.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205903_-10.0C_0060.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-210207_-10.0C_0062.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194213_-10.0C_0001.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194315_-10.1C_0002.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194530_-10.1C_0004.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194801_-10.0C_0006.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194944_-10.0C_0007.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-195159_-10.0C_0009.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-210106_-10.0C_0061.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Reject/cloud-or-haze-loss/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213943_-9.9C_0079.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Reject/missing-core-star-metrics/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-211844_-10.1C_0064.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Reject/missing-core-star-metrics/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-210207_-10.0C_0062.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Reject/missing-core-star-metrics/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-210106_-10.0C_0061.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Reject/severe-blur-or-star-trailing/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-211743_-10.4C_0063.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Reject/tracking-issue/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213943_-9.9C_0079.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Reject/tracking-issue/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-195159_-10.0C_0009.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Reject/transparency-drop/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-211743_-10.4C_0063.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Review/blur-or-star-trailing-suspected/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-211946_-10.1C_0065.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Review/tracking-needs-review/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-211946_-10.1C_0065.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Review/transparency-drop/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-211946_-10.1C_0065.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-194429_-10.1C_0003.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-194700_-10.0C_0005.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202627_-10.0C_0035.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202929_-10.0C_0037.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203149_-10.0C_0039.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203250_-10.0C_0040.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204938_-10.0C_0053.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205500_-10.0C_0057.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205601_-10.0C_0058.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194213_-10.0C_0001.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194315_-10.1C_0002.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194530_-10.1C_0004.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194801_-10.0C_0006.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213443_-10.0C_0076.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214525_-10.1C_0083.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214626_-10.0C_0084.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195044_-10.0C_0008.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195300_-10.0C_0010.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195426_-10.1C_0011.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195725_-10.1C_0013.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201116_-10.0C_0023.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201217_-10.0C_0024.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202426_-10.0C_0034.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202728_-10.0C_0036.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203029_-10.0C_0038.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203515_-10.0C_0042.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203709_-10.0C_0043.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203810_-10.0C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203924_-10.0C_0045.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204025_-10.0C_0046.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204404_-10.0C_0049.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204706_-10.0C_0051.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204807_-10.0C_0052.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205039_-10.0C_0054.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205158_-10.0C_0055.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205802_-10.1C_0059.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_178deg_60.0s_Bin1_2600MC_gain100_20260225-194944_-10.0C_0007.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212047_-10.1C_0066.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212202_-10.1C_0067.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212303_-10.1C_0068.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212542_-10.1C_0069.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212643_-10.1C_0070.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212804_-10.1C_0071.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-212905_-10.1C_0072.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213043_-10.0C_0073.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213144_-10.0C_0074.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213342_-10.0C_0075.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213644_-10.1C_0077.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-213745_-10.0C_0078.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214044_-10.0C_0080.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214245_-10.0C_0081.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214346_-10.0C_0082.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214800_-10.0C_0085.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-214901_-10.0C_0086.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-215102_-10.1C_0087.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2237_356deg_60.0s_Bin1_2600MC_gain100_20260225-215203_-10.0C_0088.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195527_-10.2C_0012.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-195826_-10.0C_0014.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200027_-9.9C_0015.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200127_-10.0C_0016.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200328_-10.0C_0017.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200429_-10.0C_0018.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200600_-9.9C_0019.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200701_-9.8C_0020.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200829_-9.9C_0021.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-200930_-10.0C_0022.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201336_-10.0C_0025.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201438_-10.0C_0026.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201550_-10.0C_0027.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201651_-10.0C_0028.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201840_-10.0C_0029.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-201953_-10.0C_0030.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202106_-10.0C_0031.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202207_-10.0C_0032.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-202325_-10.0C_0033.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-203414_-10.0C_0041.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204145_-10.0C_0047.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204246_-10.0C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-204505_-10.0C_0050.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205259_-10.1C_0056.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_177deg_60.0s_Bin1_2600MC_gain100_20260225-205903_-10.0C_0060.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report.csv
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report.html
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/00fa11c5cc79.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/011e4e551b65.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/01fbfae2caf4.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/0334b3af02b6.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/04696b0d1e7a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/048933c60962.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/050aea0ebe48.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/05749503f91d.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/06876574ddac.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/06b73d3b9980.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/0708c36107c2.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/0789f9326e6c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/0b3463735bb5.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/0c6f219daba5.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/0e977a74caf2.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/0f06a3ff980e.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/0f07400ff38a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/108fbf4c2487.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/10be33f002bb.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/12c8d8d1a96a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/16a838a28624.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/174c72b597f8.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/17f3c6fb8fcd.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/1bd85477804c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/1ce6e4b8f18d.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/1ed2ea7d8493.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/1f392475e274.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/209a43df661c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/2203e45f5ad8.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/2253e33f0485.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/26f65b3047ac.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/272df3e8b775.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/29f55a4672de.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/2a666849cfd5.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/2b100c34eb29.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/2c314cab8840.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/2d9bf5926113.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/2ff0af661ac3.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/30a6faae141d.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/31555474d317.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/34e8519c1807.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3576a1881635.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/363729ce5972.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3868a1558c67.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3880e267bafa.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/39ada13b07cf.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/39c831efb234.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3a3f2d934b95.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3a48a1b2d1b1.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3b2f509d3a5d.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3d93c5502ca1.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3dfccd3a35bb.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3e0462536f7f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/3f053937e1f0.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/407a55ffe6d2.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/40d6ee53a0b9.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/426a84f25d1c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/4284fc1d3bb8.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/42c8cc9c9793.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/4302793b9556.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/4419314f020b.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/45076d41ac6a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/492ea1f51bf1.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/4a019e49a46b.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/4b7d3a56b11e.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/4bf21df94858.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/4e24b87e604a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/51fa2205f4c1.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/53c64228f649.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/53d966053016.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/53ff739df16b.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/5493b1f4e54e.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/551cdf75740a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/591fa1e1ee4f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/59312cc267aa.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/598519fe2ca5.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/5aa021f8e205.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/5acaa6a28e5c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/5b5815b8fb4f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/5df1b53b162c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/60ac3d624d04.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/61697dcd1bef.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/6493c06e515a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/64da79b8cfbb.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/65cd921faca6.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/665713a9d2e1.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/68115f4b8102.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/691614d8a65f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/6b03f5831fe7.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/6cdf4087723a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/6d47a892fadd.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/6d746a5f09ab.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/6e02889e8c29.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/6e97f5df9866.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/6edac48b40aa.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/6edfdcc836c9.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/713c180e2120.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/71b2adcf1fe6.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/728e0359fca2.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/735dcb5101b6.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/771fec940eb9.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/777cd5be9a77.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/782e2358e9f4.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/785a34f99b5c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/78c6761824fc.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/7a2bebcf99a0.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/7a4e97665ac6.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/7b89e7e6d1c4.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/7dff86ff2da3.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/8001c179758f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/83653673d3ce.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/87e34da66bd3.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/87e391f8abce.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/891c042dc04f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/8af298dfda21.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/8b087b02beb8.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/8c2c82cc9c04.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/8cadc21489f8.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/8f9e12356349.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/9012051bcc63.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/90237e2b3428.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/9126d6d9d2f1.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/91d8bb75387a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/9848451678be.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/9db8495f4949.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/9fb5fc4f3a8e.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a162e1c5d3b8.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a18416755539.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a2dc06a433d3.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a3036cc2d6fb.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a39ba3505c80.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a525571505e6.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a5eb0357eb7a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a62e8157ab42.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a72513cf6952.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a866d13ce1e6.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/a86c92e29ebe.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/aa7882afcb0f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/ac80ca45c1e6.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/acae39293a4a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/ad422ee647f9.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/ad4f033ce980.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/ae14dd19a42f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/aeb914979ea6.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/b0f3fbeba51c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/b2a9d96fa21e.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/b31e0d9ab6f1.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/b35baee68fa1.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/b4e906c6522a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/b614e2c1512a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/b6b1df1b55c7.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/bcfaafb75634.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/bd18d46e8838.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/bd714fafcb23.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/c0577efb4a44.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/c0a9cae211bb.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/c460b2a9f9fd.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/c73afde88dfb.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/c9541ac993cd.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/cbc0b5ae7b29.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/cc4dac48dd96.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/cc5db78ff3dc.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/cf808cb249bc.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d0492d899bff.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d0dba17da8bb.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d13b6cafcab5.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d3dc5de89f6f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d4f1f837057c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d5af701130df.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d6aa77124e30.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d6b6c8b8f626.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d779b8f16af4.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/d963de47aaae.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/db374063f4ee.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/dcfde48f1311.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/e03427a5caa1.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/e27c8c224a62.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/e7169c321c6a.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/e7e9ea4abde9.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/e7f6e8c29f42.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/e97c2e4675c7.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/eb55d5f9ce89.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/eb9613f1437c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/ef3b4daaf3e8.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/effd83d182fc.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/f095e01c3395.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/f3c3078916c0.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/f4b48090edde.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/f53ca3882352.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/f755c76abb0c.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/f828e9b32694.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/f8a73a979fdb.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/f9290c99cc08.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/fa1cacc27189.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/fbb35e2fd659.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/fe05b41c1324.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/ff91675ce87f.png
sessions/NGC2237_Rosette_Nebula/2026-02-25/lights/light_frame_rating_report_assets/thumbs/ffe63f937be2.png
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Drizzle/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og_work_.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_manual_strech.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_strech.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_seti.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_seti_strech.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_workú.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/New/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_starnet_two_x_test.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/NGC_2244_Satellite_Cluster_009x60sec_540s_2026-03-16_1958_og.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-224434_355deg_-10.1C_0001.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-224536_355deg_-10.1C_0002.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-224737_355deg_-10.0C_0003.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-224838_355deg_-10.0C_0004.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-224954_355deg_-10.0C_0005.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-225055_355deg_-10.1C_0006.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-225210_355deg_-10.1C_0007.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-225413_355deg_-10.0C_0008.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-225603_355deg_-10.0C_0009.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/lights/Light_NGC 2244 Satellite Cluster_60.0s_Bin1_2600MC_gain100_20260315-225704_355deg_-10.0C_0010.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/NGC_2244_Satellite_Cluster_044x120sec_5280s__drizzle-2-0x_2026-03-17_1843_og.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/NGC_2244_Satellite_Cluster_047x120sec_5640s_2026-03-16_1941_og.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-195204_356deg_-10.2C_0001.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-195405_356deg_-10.0C_0002.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-195632_356deg_-10.0C_0003.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-200034_356deg_-10.0C_0004.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-200444_356deg_-9.9C_0005.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-200645_356deg_-10.0C_0006.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-200856_356deg_-10.0C_0007.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-201259_356deg_-10.0C_0008.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-201517_356deg_-9.9C_0009.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-201719_356deg_-10.0C_0010.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-201955_356deg_-10.0C_0011.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-202155_356deg_-10.0C_0012.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-202422_356deg_-10.0C_0013.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-202623_356deg_-10.0C_0014.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-202843_356deg_-10.0C_0015.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203043_356deg_-10.0C_0016.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203304_356deg_-10.0C_0017.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203505_356deg_-10.0C_0018.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203719_356deg_-9.9C_0019.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203920_356deg_-10.0C_0020.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-204134_356deg_-10.0C_0021.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-204335_356deg_-9.9C_0022.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-204601_356deg_-10.0C_0023.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-204802_356deg_-10.0C_0024.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205019_356deg_-10.0C_0025.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205220_356deg_-10.0C_0026.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205428_356deg_-10.0C_0027.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205629_356deg_-10.0C_0028.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205847_356deg_-10.0C_0029.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-210048_356deg_-10.0C_0030.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-210300_356deg_-10.0C_0031.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-210702_356deg_-10.0C_0032.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-210910_356deg_-10.0C_0033.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-211111_356deg_-10.0C_0034.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-211324_356deg_-10.0C_0035.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-211525_356deg_-10.0C_0036.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-212147_356deg_-4.8C_0037.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-212348_356deg_-10.7C_0038.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-212618_356deg_-9.8C_0039.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-212819_356deg_-10.0C_0040.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-213033_356deg_-10.1C_0041.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-213435_356deg_-10.0C_0042.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-213658_356deg_-10.0C_0043.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214101_356deg_-10.1C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214313_356deg_-10.0C_0045.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214514_356deg_-10.0C_0046.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214738_356deg_-10.0C_0047.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214938_356deg_-10.0C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-215151_356deg_-10.0C_0049.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-215352_356deg_-10.0C_0050.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-215609_356deg_-10.0C_0051.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-215811_355deg_-10.0C_0052.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220024_356deg_-9.9C_0053.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220224_356deg_-10.0C_0054.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220436_356deg_-9.9C_0055.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220637_356deg_-10.0C_0056.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220856_356deg_-10.0C_0057.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-221057_356deg_-10.0C_0058.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-221310_356deg_-9.9C_0059.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-221511_356deg_-9.8C_0060.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-221727_356deg_-9.9C_0061.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Reject/cloud-or-haze-loss/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-221727_356deg_-9.9C_0061.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Reject/tracking-issue/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-195405_356deg_-10.0C_0002.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Reject/tracking-issue/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205847_356deg_-10.0C_0029.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Reject/tracking-issue/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-211324_356deg_-10.0C_0035.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Reject/tracking-issue/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-213435_356deg_-10.0C_0042.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Reject/tracking-issue/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214938_356deg_-10.0C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Reject/tracking-issue/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-215609_356deg_-10.0C_0051.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Reject/tracking-issue/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-221057_356deg_-10.0C_0058.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Reject/tracking-needs-review/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-221727_356deg_-9.9C_0061.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Review/background-needs-review-gradient/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214101_356deg_-10.1C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Review/tracking-needs-review/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214101_356deg_-10.1C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-195632_356deg_-10.0C_0003.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-200444_356deg_-9.9C_0005.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-200645_356deg_-10.0C_0006.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-200856_356deg_-10.0C_0007.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-201259_356deg_-10.0C_0008.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-202155_356deg_-10.0C_0012.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-202843_356deg_-10.0C_0015.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203043_356deg_-10.0C_0016.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203304_356deg_-10.0C_0017.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203505_356deg_-10.0C_0018.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203719_356deg_-9.9C_0019.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-204134_356deg_-10.0C_0021.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-210300_356deg_-10.0C_0031.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-210702_356deg_-10.0C_0032.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-210910_356deg_-10.0C_0033.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-211111_356deg_-10.0C_0034.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-212618_356deg_-9.8C_0039.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Best/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-212819_356deg_-10.0C_0040.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-195204_356deg_-10.2C_0001.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-200034_356deg_-10.0C_0004.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-201517_356deg_-9.9C_0009.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-201719_356deg_-10.0C_0010.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-201955_356deg_-10.0C_0011.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-202422_356deg_-10.0C_0013.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-202623_356deg_-10.0C_0014.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-203920_356deg_-10.0C_0020.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-204601_356deg_-10.0C_0023.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-204802_356deg_-10.0C_0024.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205019_356deg_-10.0C_0025.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205220_356deg_-10.0C_0026.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205428_356deg_-10.0C_0027.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-205629_356deg_-10.0C_0028.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-211525_356deg_-10.0C_0036.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214514_356deg_-10.0C_0046.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214738_356deg_-10.0C_0047.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220024_356deg_-9.9C_0053.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220436_356deg_-9.9C_0055.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Good/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-221310_356deg_-9.9C_0059.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-204335_356deg_-9.9C_0022.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-210048_356deg_-10.0C_0030.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-212147_356deg_-4.8C_0037.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-212348_356deg_-10.7C_0038.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-213033_356deg_-10.1C_0041.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-213658_356deg_-10.0C_0043.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-214313_356deg_-10.0C_0045.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-215151_356deg_-10.0C_0049.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-215352_356deg_-10.0C_0050.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-215811_355deg_-10.0C_0052.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220224_356deg_-10.0C_0054.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220637_356deg_-10.0C_0056.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-220856_356deg_-10.0C_0057.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/lights/Stack/Ok/Light_NGC 2244 Satellite Cluster_120.0s_Bin1_2600MC_gain100_20260315-221511_356deg_-9.8C_0060.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-210625_356deg_-10.0C_0001.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-210826_356deg_-10.1C_0002.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211047_356deg_-10.0C_0003.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211248_356deg_-10.0C_0004.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211505_356deg_-10.0C_0005.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211706_356deg_-10.0C_0006.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211925_356deg_-10.0C_0007.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212126_356deg_-10.0C_0008.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212342_356deg_-10.0C_0009.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212543_356deg_-10.0C_0010.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212756_356deg_-10.0C_0011.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212957_356deg_-10.0C_0012.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213217_356deg_-10.0C_0013.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213418_356deg_-10.0C_0014.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213637_356deg_-10.1C_0015.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213838_355deg_-10.0C_0016.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214053_356deg_-10.0C_0017.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214254_356deg_-10.1C_0018.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214515_356deg_-10.0C_0019.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214716_356deg_-10.0C_0020.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214929_356deg_-10.0C_0021.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-215129_355deg_-9.9C_0022.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-215344_355deg_-10.0C_0023.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-215545_355deg_-10.0C_0024.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-215808_355deg_-10.0C_0025.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220009_355deg_-10.0C_0026.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220229_356deg_-10.0C_0027.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220430_356deg_-10.0C_0028.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220647_356deg_-10.0C_0029.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220849_356deg_-10.0C_0030.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221111_356deg_-10.0C_0031.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221312_356deg_-10.0C_0032.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221526_355deg_-10.0C_0033.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221727_355deg_-10.0C_0034.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221947_355deg_-10.0C_0035.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-222149_355deg_-10.1C_0036.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-222403_355deg_-10.0C_0037.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-222604_355deg_-10.0C_0038.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-222830_355deg_-10.0C_0039.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223031_355deg_-10.0C_0040.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223243_355deg_-10.0C_0041.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223444_355deg_-10.0C_0042.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223657_355deg_-10.1C_0043.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223858_356deg_-10.0C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224125_355deg_-10.0C_0045.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224326_355deg_-10.0C_0046.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224627_356deg_-10.0C_0047.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224828_356deg_-10.1C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-225109_356deg_-10.0C_0049.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/background-needs-review-gradient-noise/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213637_356deg_-10.1C_0015.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/background-needs-review-level-noise/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223243_355deg_-10.0C_0041.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/blur-or-star-trailing-suspected/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223444_355deg_-10.0C_0042.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/blur-or-star-trailing-suspected/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223657_355deg_-10.1C_0043.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/blur-or-star-trailing-suspected/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223858_356deg_-10.0C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/cloud-or-haze-loss/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223243_355deg_-10.0C_0041.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/cloud-or-haze-loss/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223444_355deg_-10.0C_0042.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/cloud-or-haze-loss/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223657_355deg_-10.1C_0043.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/cloud-or-haze-loss/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223858_356deg_-10.0C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/cloud-or-haze-loss/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224125_355deg_-10.0C_0045.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/cloud-or-haze-loss/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224326_355deg_-10.0C_0046.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/cloud-or-haze-loss/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224627_356deg_-10.0C_0047.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/cloud-or-haze-loss/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224828_356deg_-10.1C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/cloud-or-haze-loss/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-225109_356deg_-10.0C_0049.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient-level-noise/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223657_355deg_-10.1C_0043.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient-level-noise/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224326_355deg_-10.0C_0046.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient-level-noise/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224828_356deg_-10.1C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient-level/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-222403_355deg_-10.0C_0037.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient-level/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223031_355deg_-10.0C_0040.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211706_356deg_-10.0C_0006.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212126_356deg_-10.0C_0008.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212342_356deg_-10.0C_0009.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212957_356deg_-10.0C_0012.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213838_355deg_-10.0C_0016.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214254_356deg_-10.1C_0018.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214515_356deg_-10.0C_0019.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214716_356deg_-10.0C_0020.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214929_356deg_-10.0C_0021.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-215129_355deg_-9.9C_0022.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-215344_355deg_-10.0C_0023.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-215545_355deg_-10.0C_0024.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-215808_355deg_-10.0C_0025.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-level-gradient-noise/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223444_355deg_-10.0C_0042.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-level-gradient-noise/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-225109_356deg_-10.0C_0049.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-level-noise-gradient/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224125_355deg_-10.0C_0045.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/heavy-background-issue-level-noise/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223858_356deg_-10.0C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/severe-blur-or-star-trailing/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213637_356deg_-10.1C_0015.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/severe-blur-or-star-trailing/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224125_355deg_-10.0C_0045.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/severe-blur-or-star-trailing/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224326_355deg_-10.0C_0046.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/severe-blur-or-star-trailing/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224627_356deg_-10.0C_0047.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/severe-blur-or-star-trailing/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224828_356deg_-10.1C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/severe-blur-or-star-trailing/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-225109_356deg_-10.0C_0049.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223031_355deg_-10.0C_0040.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223243_355deg_-10.0C_0041.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223444_355deg_-10.0C_0042.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223657_355deg_-10.1C_0043.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-223858_356deg_-10.0C_0044.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224125_355deg_-10.0C_0045.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224326_355deg_-10.0C_0046.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224627_356deg_-10.0C_0047.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224828_356deg_-10.1C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-225109_356deg_-10.0C_0049.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/tracking-needs-review/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211706_356deg_-10.0C_0006.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/tracking-needs-review/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212342_356deg_-10.0C_0009.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/tracking-needs-review/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214515_356deg_-10.0C_0019.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/tracking-needs-review/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-224828_356deg_-10.1C_0048.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Reject/transparency-drop/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213637_356deg_-10.1C_0015.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Review/background-needs-review-level-noise/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220229_356deg_-10.0C_0027.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Review/soft-stars/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-222149_355deg_-10.1C_0036.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Review/transparency-drop/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220229_356deg_-10.0C_0027.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Best/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-210826_356deg_-10.1C_0002.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Good/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-210625_356deg_-10.0C_0001.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Good/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211047_356deg_-10.0C_0003.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Good/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211248_356deg_-10.0C_0004.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Good/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211505_356deg_-10.0C_0005.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Good/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212543_356deg_-10.0C_0010.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Good/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-212756_356deg_-10.0C_0011.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Good/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213418_356deg_-10.0C_0014.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Good/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220849_356deg_-10.0C_0030.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-211925_356deg_-10.0C_0007.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-213217_356deg_-10.0C_0013.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-214053_356deg_-10.0C_0017.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220009_355deg_-10.0C_0026.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220430_356deg_-10.0C_0028.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-220647_356deg_-10.0C_0029.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221111_356deg_-10.0C_0031.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221312_356deg_-10.0C_0032.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221526_355deg_-10.0C_0033.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221727_355deg_-10.0C_0034.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-221947_355deg_-10.0C_0035.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-222604_355deg_-10.0C_0038.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/Stack/Ok/Light_IC 1805_120.0s_Bin1_2600MC_gain100_20260405-222830_355deg_-10.0C_0039.fit
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report.csv
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report.html
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/00fa11c5cc79.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/011e4e551b65.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/01fbfae2caf4.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/0334b3af02b6.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/04696b0d1e7a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/048933c60962.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/050aea0ebe48.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/05749503f91d.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/06876574ddac.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/06b73d3b9980.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/0708c36107c2.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/0789f9326e6c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/0b3463735bb5.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/0c6f219daba5.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/0e977a74caf2.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/0f06a3ff980e.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/0f07400ff38a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/108fbf4c2487.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/10be33f002bb.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/12c8d8d1a96a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/16a838a28624.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/174c72b597f8.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/17f3c6fb8fcd.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/1bd85477804c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/1ce6e4b8f18d.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/1ed2ea7d8493.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/1f392475e274.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/209a43df661c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/2203e45f5ad8.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/2253e33f0485.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/26f65b3047ac.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/272df3e8b775.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/29f55a4672de.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/2a666849cfd5.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/2b100c34eb29.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/2c314cab8840.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/2d9bf5926113.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/2ff0af661ac3.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/30a6faae141d.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/31555474d317.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/34e8519c1807.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3576a1881635.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/363729ce5972.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3868a1558c67.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3880e267bafa.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/39ada13b07cf.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/39c831efb234.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3a3f2d934b95.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3a48a1b2d1b1.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3b2f509d3a5d.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3d93c5502ca1.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3dfccd3a35bb.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3e0462536f7f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/3f053937e1f0.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/407a55ffe6d2.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/40d6ee53a0b9.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/426a84f25d1c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/4284fc1d3bb8.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/42c8cc9c9793.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/4302793b9556.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/4419314f020b.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/45076d41ac6a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/492ea1f51bf1.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/4a019e49a46b.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/4b7d3a56b11e.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/4bf21df94858.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/4e24b87e604a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/51fa2205f4c1.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/53c64228f649.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/53d966053016.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/53ff739df16b.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/5493b1f4e54e.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/551cdf75740a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/591fa1e1ee4f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/59312cc267aa.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/598519fe2ca5.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/5aa021f8e205.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/5acaa6a28e5c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/5b5815b8fb4f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/5df1b53b162c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/60ac3d624d04.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/61697dcd1bef.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/6493c06e515a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/64da79b8cfbb.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/65cd921faca6.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/665713a9d2e1.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/68115f4b8102.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/691614d8a65f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/6b03f5831fe7.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/6cdf4087723a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/6d47a892fadd.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/6d746a5f09ab.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/6e02889e8c29.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/6e97f5df9866.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/6edac48b40aa.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/6edfdcc836c9.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/713c180e2120.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/71b2adcf1fe6.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/728e0359fca2.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/735dcb5101b6.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/771fec940eb9.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/777cd5be9a77.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/782e2358e9f4.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/785a34f99b5c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/78c6761824fc.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/7a2bebcf99a0.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/7a4e97665ac6.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/7b89e7e6d1c4.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/7dff86ff2da3.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/8001c179758f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/83653673d3ce.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/87e34da66bd3.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/87e391f8abce.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/891c042dc04f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/8af298dfda21.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/8b087b02beb8.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/8c2c82cc9c04.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/8cadc21489f8.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/8f9e12356349.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/9012051bcc63.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/90237e2b3428.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/9126d6d9d2f1.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/91d8bb75387a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/9848451678be.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/9db8495f4949.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/9fb5fc4f3a8e.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a162e1c5d3b8.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a18416755539.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a2dc06a433d3.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a3036cc2d6fb.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a39ba3505c80.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a525571505e6.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a5eb0357eb7a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a62e8157ab42.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a72513cf6952.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a866d13ce1e6.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/a86c92e29ebe.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/aa7882afcb0f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/ac80ca45c1e6.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/acae39293a4a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/ad422ee647f9.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/ad4f033ce980.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/ae14dd19a42f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/aeb914979ea6.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/b0f3fbeba51c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/b2a9d96fa21e.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/b31e0d9ab6f1.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/b35baee68fa1.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/b4e906c6522a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/b614e2c1512a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/b6b1df1b55c7.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/bcfaafb75634.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/bd18d46e8838.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/bd714fafcb23.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/c0577efb4a44.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/c0a9cae211bb.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/c460b2a9f9fd.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/c73afde88dfb.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/c9541ac993cd.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/cbc0b5ae7b29.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/cc4dac48dd96.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/cc5db78ff3dc.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/cf808cb249bc.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d0492d899bff.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d0dba17da8bb.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d13b6cafcab5.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d3dc5de89f6f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d4f1f837057c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d5af701130df.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d6aa77124e30.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d6b6c8b8f626.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d779b8f16af4.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/d963de47aaae.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/db374063f4ee.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/dcfde48f1311.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/e03427a5caa1.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/e27c8c224a62.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/e7169c321c6a.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/e7e9ea4abde9.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/e7f6e8c29f42.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/e97c2e4675c7.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/eb55d5f9ce89.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/eb9613f1437c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/ef3b4daaf3e8.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/effd83d182fc.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/f095e01c3395.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/f3c3078916c0.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/f4b48090edde.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/f53ca3882352.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/f755c76abb0c.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/f828e9b32694.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/f8a73a979fdb.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/f9290c99cc08.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/fa1cacc27189.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/fbb35e2fd659.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/fe05b41c1324.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/ff91675ce87f.png
sessions/NGC2237_Rosette_Nebula/2026-04-05/lights/light_frame_rating_report_assets/thumbs/ffe63f937be2.png
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-015928_178deg_-10.0C_0093.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-020129_178deg_-10.0C_0094.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-020352_178deg_-10.0C_0095.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-020553_178deg_-10.0C_0096.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-020817_178deg_-10.0C_0097.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-021018_178deg_-10.0C_0098.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-021241_178deg_-10.0C_0099.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-021443_178deg_-9.9C_0100.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-021703_178deg_-10.0C_0101.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-021904_178deg_-10.0C_0102.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-022126_178deg_-10.1C_0103.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-022326_178deg_-10.0C_0104.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-022543_178deg_-10.0C_0105.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-022744_178deg_-10.0C_0106.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-023006_178deg_-10.0C_0107.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-023207_178deg_-10.0C_0108.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-023428_178deg_-10.0C_0109.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-023630_178deg_-10.0C_0110.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-023839_178deg_-10.0C_0111.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-024040_178deg_-10.0C_0112.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-024256_178deg_-10.0C_0113.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-024457_178deg_-10.0C_0114.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-024717_178deg_-10.0C_0115.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-024918_178deg_-10.0C_0116.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-025138_178deg_-10.0C_0117.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-025339_178deg_-10.0C_0118.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-025550_178deg_-10.0C_0119.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-025752_178deg_-10.0C_0120.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-030010_178deg_-10.0C_0121.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-030210_178deg_-10.0C_0122.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-030422_178deg_-10.0C_0123.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-030623_178deg_-10.0C_0124.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-030834_178deg_-10.0C_0125.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-031035_178deg_-10.0C_0126.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Junk/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-033859_178deg_-10.0C_0139.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224059_178deg_-10.0C_0001.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224059_178deg_-10.0C_0001.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224300_178deg_-10.0C_0002.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224300_178deg_-10.0C_0002.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224522_178deg_-10.0C_0003.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224522_178deg_-10.0C_0003.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224723_178deg_-10.0C_0004.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224723_178deg_-10.0C_0004.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224939_178deg_-10.0C_0005.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-224939_178deg_-10.0C_0005.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-225140_178deg_-10.0C_0006.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-225140_178deg_-10.0C_0006.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-225359_178deg_-10.0C_0007.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-225359_178deg_-10.0C_0007.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-225600_178deg_-10.0C_0008.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-225600_178deg_-10.0C_0008.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-225817_178deg_-10.0C_0009.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-225817_178deg_-10.0C_0009.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230018_178deg_-10.1C_0010.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230018_178deg_-10.1C_0010.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230228_178deg_-10.0C_0011.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230228_178deg_-10.0C_0011.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230429_178deg_-10.0C_0012.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230429_178deg_-10.0C_0012.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230643_178deg_-10.0C_0013.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230643_178deg_-10.0C_0013.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230844_178deg_-10.0C_0014.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-230844_178deg_-10.0C_0014.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231104_178deg_-10.0C_0015.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231104_178deg_-10.0C_0015.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231305_178deg_-10.0C_0016.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231305_178deg_-10.0C_0016.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231518_178deg_-10.0C_0017.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231518_178deg_-10.0C_0017.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231719_178deg_-10.0C_0018.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231719_178deg_-10.0C_0018.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231931_178deg_-10.0C_0019.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-231931_178deg_-10.0C_0019.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-232133_178deg_-10.0C_0020.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-232133_178deg_-10.0C_0020.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-232351_178deg_-10.0C_0021.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-232351_178deg_-10.0C_0021.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-232552_178deg_-10.0C_0022.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-232552_178deg_-10.0C_0022.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-232814_178deg_-10.0C_0023.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-232814_178deg_-10.0C_0023.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233015_178deg_-10.0C_0024.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233015_178deg_-10.0C_0024.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233232_178deg_-10.0C_0025.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233232_178deg_-10.0C_0025.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233433_178deg_-10.0C_0026.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233433_178deg_-10.0C_0026.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233650_178deg_-10.0C_0027.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233650_178deg_-10.0C_0027.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233851_178deg_-10.0C_0028.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-233851_178deg_-10.0C_0028.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234105_178deg_-10.0C_0029.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234105_178deg_-10.0C_0029.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234306_178deg_-10.0C_0030.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234306_178deg_-10.0C_0030.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234526_178deg_-10.0C_0031.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234526_178deg_-10.0C_0031.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234727_178deg_-10.0C_0032.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234727_178deg_-10.0C_0032.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234943_178deg_-10.0C_0033.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-234943_178deg_-10.0C_0033.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-235144_178deg_-10.0C_0034.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-235144_178deg_-10.0C_0034.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-235402_178deg_-10.0C_0035.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-235402_178deg_-10.0C_0035.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-235603_178deg_-10.0C_0036.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-235603_178deg_-10.0C_0036.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-235812_178deg_-10.0C_0037.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260522-235812_178deg_-10.0C_0037.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000013_178deg_-10.0C_0038.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000013_178deg_-10.0C_0038.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000224_178deg_-10.0C_0039.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000224_178deg_-10.0C_0039.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000425_178deg_-10.0C_0040.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000425_178deg_-10.0C_0040.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000655_178deg_-10.0C_0041.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000655_178deg_-10.0C_0041.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000856_178deg_-10.0C_0042.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-000856_178deg_-10.0C_0042.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-001119_178deg_-10.0C_0043.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-001119_178deg_-10.0C_0043.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-001319_178deg_-10.0C_0044.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-001319_178deg_-10.0C_0044.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-001551_178deg_-10.0C_0045.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-001551_178deg_-10.0C_0045.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-001752_178deg_-10.0C_0046.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-001752_178deg_-10.0C_0046.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002004_178deg_-10.0C_0047.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002004_178deg_-10.0C_0047.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002204_178deg_-9.9C_0048.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002204_178deg_-9.9C_0048.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002417_178deg_-10.0C_0049.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002417_178deg_-10.0C_0049.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002618_178deg_-10.0C_0050.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002618_178deg_-10.0C_0050.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002837_178deg_-9.9C_0051.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-002837_178deg_-9.9C_0051.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003038_178deg_-10.0C_0052.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003038_178deg_-10.0C_0052.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003252_178deg_-10.0C_0053.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003252_178deg_-10.0C_0053.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003453_178deg_-10.0C_0054.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003453_178deg_-10.0C_0054.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003714_178deg_-10.0C_0055.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003714_178deg_-10.0C_0055.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003915_178deg_-10.0C_0056.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-003915_178deg_-10.0C_0056.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-004132_178deg_-10.0C_0057.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-004132_178deg_-10.0C_0057.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-004333_178deg_-10.0C_0058.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-004333_178deg_-10.0C_0058.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-004550_178deg_-10.0C_0059.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-004550_178deg_-10.0C_0059.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005013_178deg_-10.0C_0061.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005013_178deg_-10.0C_0061.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005213_178deg_-10.0C_0062.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005213_178deg_-10.0C_0062.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005433_178deg_-10.0C_0063.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005433_178deg_-10.0C_0063.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005634_178deg_-10.0C_0064.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005634_178deg_-10.0C_0064.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005853_178deg_-10.0C_0065.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-005853_178deg_-10.0C_0065.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010054_178deg_-10.0C_0066.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010054_178deg_-10.0C_0066.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010309_178deg_-10.0C_0067.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010309_178deg_-10.0C_0067.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010510_178deg_-10.0C_0068.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010510_178deg_-10.0C_0068.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010733_178deg_-10.0C_0069.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010733_178deg_-10.0C_0069.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010934_178deg_-10.0C_0070.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-010934_178deg_-10.0C_0070.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-011146_178deg_-10.0C_0071.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-011146_178deg_-10.0C_0071.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-011346_178deg_-10.0C_0072.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-011346_178deg_-10.0C_0072.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-011611_178deg_-10.0C_0073.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-011611_178deg_-10.0C_0073.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-011812_178deg_-9.9C_0074.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-011812_178deg_-9.9C_0074.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012028_178deg_-10.0C_0075.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012028_178deg_-10.0C_0075.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012229_178deg_-10.0C_0076.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012229_178deg_-10.0C_0076.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012453_178deg_-10.0C_0077.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012453_178deg_-10.0C_0077.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012653_178deg_-10.0C_0078.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012653_178deg_-10.0C_0078.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012913_178deg_-10.0C_0079.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-012913_178deg_-10.0C_0079.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-013114_178deg_-10.0C_0080.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-013114_178deg_-10.0C_0080.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-013332_178deg_-10.0C_0081.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-013332_178deg_-10.0C_0081.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-013533_178deg_-10.0C_0082.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-013533_178deg_-10.0C_0082.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-013759_178deg_-10.1C_0083.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-013759_178deg_-10.1C_0083.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014000_178deg_-10.0C_0084.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014000_178deg_-10.0C_0084.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014209_178deg_-10.0C_0085.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014209_178deg_-10.0C_0085.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014411_178deg_-10.0C_0086.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014411_178deg_-10.0C_0086.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014629_178deg_-10.1C_0087.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014629_178deg_-10.1C_0087.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014830_178deg_-10.0C_0088.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-014830_178deg_-10.0C_0088.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-015048_178deg_-10.0C_0089.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-015048_178deg_-10.0C_0089.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-015249_178deg_-10.0C_0090.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-015249_178deg_-10.0C_0090.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-015505_178deg_-10.0C_0091.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-015505_178deg_-10.0C_0091.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-015707_178deg_-9.9C_0092.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-015707_178deg_-9.9C_0092.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-031257_178deg_-10.0C_0127.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-031257_178deg_-10.0C_0127.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-031458_178deg_-10.0C_0128.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-031458_178deg_-10.0C_0128.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-031716_178deg_-10.0C_0129.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-031716_178deg_-10.0C_0129.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-031918_178deg_-10.0C_0130.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-031918_178deg_-10.0C_0130.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-032137_178deg_-10.0C_0131.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-032137_178deg_-10.0C_0131.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-032337_178deg_-10.0C_0132.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-032337_178deg_-10.0C_0132.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-032555_178deg_-10.0C_0133.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-032555_178deg_-10.0C_0133.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-032756_178deg_-10.0C_0134.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-032756_178deg_-10.0C_0134.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-033017_178deg_-10.0C_0135.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-033017_178deg_-10.0C_0135.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-033218_178deg_-9.9C_0136.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-033218_178deg_-9.9C_0136.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-033437_178deg_-10.0C_0137.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-033437_178deg_-10.0C_0137.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-033638_178deg_-9.9C_0138.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-033638_178deg_-9.9C_0138.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-034100_178deg_-10.0C_0140.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-034100_178deg_-10.0C_0140.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-034320_178deg_-10.0C_0141.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-034320_178deg_-10.0C_0141.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-034522_178deg_-10.0C_0142.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-034522_178deg_-10.0C_0142.info.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/lights/Light_NGC 7000_120.stackinfo.txt
sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_Ha_12720s.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_OIII_12720s.fit
"""

    private static let rawScannerReachableCleanPaths = """
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/FOV______017x60sec_1020s_drizzle-1-0x_2026-04-24_1806_og.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/Light_FOV_60.0s_Bin1_2600MC_gain100_20260418-042915_231deg_-10.0C_0009.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/individual_stacks/FOV______017x60sec_1020s_drizzle-1-0x_2026-04-24_1806_session1.fit
sessions/C2025_R3_C2025_R3_Panstarrs/2026-04-18/test_00001.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-192707_-9.9C_0001.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193123_-10.0C_0003.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193323_-10.0C_0004.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193533_-10.0C_0005.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193734_-9.9C_0006.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-193944_-10.0C_0007.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_179deg_120.0s_Bin1_2600MC_gain100_20260117-194145_-10.0C_0008.fit
sessions/IC1805-1848_Heart-and-Soul_Nebula/2026-01-17/Light_Hearth 3_187deg_120.0s_Bin1_2600MC_gain100_20260117-192907_-10.0C_0002.fit
sessions/M42_Orion/2026-01-17/FOV______123x60sec_7380s_2026-01-19_2033_og.fit
sessions/M42_Orion/2026-01-17/FOV______136x60sec_8160s_2026-01-22_2045_og.fit
sessions/M42_Orion/2026-01-17/FOV______136x60sec_8160s_2026-01-22_2045_og_pixisgnist.fit
sessions/M42_Orion/2026-01-17/FOV______136x60sec_8160s_2026-01-22_2045_og_process.fit
sessions/M42_Orion/2026-01-17/FOV______160x60sec_9600s__drizzle-1-5x_2026-01-22_1625_og.fit
sessions/M42_Orion/2026-01-17/FOV______160x60sec_9600s__drizzle-1-5x_2026-01-22_1625_og_og.fit
sessions/M42_Orion/2026-01-17/FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process.fit
sessions/M42_Orion/2026-01-17/FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_2.fit
sessions/M42_Orion/2026-01-17/FOV______161x60sec_9660s__drizzle-1-5x_2026-01-19_2102_og_process_test.fit
sessions/M84_Markarians_Chain/2026-04-18/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1459_og.fit
sessions/M84_Markarians_Chain/2026-04-18/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1502_og.fit
sessions/M84_Markarians_Chain/2026-04-18/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1507_og.fit
sessions/M84_Markarians_Chain/2026-04-18/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1511_og.fit
sessions/M84_Markarians_Chain/2026-04-18/individual_stacks/Markarians_Chain_027x180sec_4860s_drizzle-1-0x_2026-04-18_1511_session1.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25/NGC_2237_085x60sec_5100s_2026-03-01_1629_og.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/Drizzle/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_130x120sec_11460s_2026-03-16_1956_og.fit
sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15-OSC/NGC_2244_Satellite_Cluster_009x60sec_540s_2026-03-16_1958_og.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/NGC_2244_Satellite_Cluster_044x120sec_5280s__drizzle-2-0x_2026-03-17_1843_og.fit
sessions/NGC2237_Rosette_Nebula/2026-03-15/NGC_2244_Satellite_Cluster_047x120sec_5640s_2026-03-16_1941_og.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_Ha_12720s.fit
sessions/NGC_7000_North_American_Nebula/2026-05-23/results/result_OIII_12720s.fit
"""
}
