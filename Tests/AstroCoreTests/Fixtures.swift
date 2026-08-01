import Foundation

/// Shared fixture-tree builder used by the scanner, audit, and duplicate
/// tests. Builds the "mess catalog" described in PROMPT.md — every weird
/// real-world case the tool needs to recognize — as empty directories and
/// tiny dummy files under a temp directory. Tests must never touch the real
/// (TCC-protected) library; this is the only tree they're allowed to scan.
enum Fixtures {
    /// Builds the messy library directly under `tmpDir` (i.e. `tmpDir` *is*
    /// the library root — no extra `Astro/` layer) and returns that root
    /// URL back to the caller for convenience.
    @discardableResult
    static func makeMessyLibrary(in tmpDir: URL) throws -> URL {
        let root = tmpDir
        let fm = FileManager.default

        @discardableResult
        func makeDir(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @discardableResult
        func makeFile(_ relativePath: String, content: String? = nil) throws -> URL {
            let url = root.appendingPathComponent(relativePath, isDirectory: false)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = content ?? "fixture dummy content: \(relativePath)\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        // MARK: Normal session with lights + README, plus flats/darks/biases dirs.
        try makeFile("sessions/M45_Pleiades/2026-01-10/lights/light_0001.fit")
        try makeFile("sessions/M45_Pleiades/2026-01-10/lights/light_0002.fit")
        try makeFile("sessions/M45_Pleiades/2026-01-10/lights/light_0003.fit")
        try makeDir("sessions/M45_Pleiades/2026-01-10/flats")
        try makeDir("sessions/M45_Pleiades/2026-01-10/darks")
        try makeDir("sessions/M45_Pleiades/2026-01-10/biases")
        try makeFile(
            "sessions/M45_Pleiades/2026-01-10/README.txt",
            content: "Camera: ZWO ASI2600MC Pro\nExposure (lights): 300s\n"
        )

        // Session with NO matching stack.
        try makeFile("sessions/IC1805-1848_Heart_and_Soul_Nebula/2026-01-17/lights/light_0001.fit")
        try makeFile("sessions/IC1805-1848_Heart_and_Soul_Nebula/2026-01-17/lights/light_0002.fit")

        // MARK: Placeholder target name that never got renamed.
        try makeFile("stacks/Please_enter_a_value.._Milkyway/2026-04-19/stack.fit")
        try makeFile("stacks/M_Milky_Way/2026-04-19/stack.fit")

        // MARK: Comet triplet — same object, three near-duplicate target names.
        try makeFile("stacks/R3_C2025/2026-10-01/stack.fit")
        try makeFile("stacks/C2025_R3_C2025_R3_Panstarrs/2026-10-01/stack.fit")
        try makeFile("stacks/C2025_R3_C2025_R3_Panstarrs_Wide/2026-10-01/stack.fit")

        // MARK: M42 family — same object, four near-duplicate target names.
        try makeFile("stacks/M42_Orion/2026-01-17/result.fit")
        try makeFile("stacks/M42_Orion_Nebula/2026-01-18/stack.fit")
        try makeFile("stacks/M42_Orion_wide_field/2026-01-18/stack.fit")
        try makeFile("stacks/M42_Orion_Wide_Field_70MM/2026-01-18/stack.fit")

        // MARK: Calibration library, plus an orphan "bias" (singular) dir.
        try makeFile("calibration_library/darks/60sec_-10deg/master_dark.fit")
        try makeFile("calibration_library/darks/300sec_-10deg/master_dark.fit")
        try makeFile("calibration_library/biases/master_bias.fit")
        try makeFile("calibration_library/bias/stray.fit")

        // MARK: Date-folder variants under sessions/M45_Pleiades.
        try makeFile("sessions/M45_Pleiades/2026-04-06-2/lights/light_0001.fit")
        try makeFile("sessions/M45_Pleiades/2026-02-25_2026-03-15/lights/light_0001.fit")
        try makeFile("sessions/M45_Pleiades/2026-03-15-OSC/lights/light_0001.fit")
        try makeFile("sessions/M45_Pleiades/2026-03-15_hibas/lights/light_0001.fit")

        // MARK: Nested "sessions" tree under stacks — a mislabeling the
        // audit engine (later task) flags; the classifier must NOT treat it
        // as area .sessions just because of the nested folder name.
        try makeFile("stacks/M42_Orion/2026-01-17/sessions/session1/lights/nested_light.fit")
        try makeDir("stacks/M42_Orion/2026-01-17/sessions/session1/flats")
        try makeFile("stacks/M42_Orion/2026-01-17/collected_lights/a.fit")
        try makeFile("stacks/M_Milky_Way/2026-04-19/paneled_mosaic_process/lights/b.fit")

        // MARK: Report/asset folder with no date component, alongside a
        // normal dated stack for the same target.
        try makeFile("stacks/NGC2237_Rosette_Nebula/light_frame_rating_report_assets/plot.png")
        try makeFile("stacks/NGC2237_Rosette_Nebula/2026-05-29/stack.fit")

        // MARK: Missing counterparts: stacks with no session, processed
        // with no session and no stack for that date.
        try makeFile("stacks/NGC_7000_North_America/2026-06-06/s.fit")
        try makeFile("stacks/NGC_7000_North_America/2026-06-29/s.fit")
        try makeFile("processed/NGC2237_Rosette_Nebula/2026-07-01/final.tif")

        // MARK: Stacking residue left behind under a real stack date dir.
        try makeFile("stacks/M42_Orion/2026-01-17/x.seq")
        try makeFile("stacks/M42_Orion/2026-01-17/x.lst")
        try makeFile("stacks/M42_Orion/2026-01-17/r_lights.fit")
        try makeFile("stacks/M42_Orion/2026-01-17/.DS_Store")
        try makeFile("stacks/M42_Orion/2026-01-17/process/leftover.tmp")

        // MARK: Decoys that MUST be excluded from every scan.
        try makeFile("tools/setiastro/test.fits")
        try makeFile(".astro_tool/astrotool.sqlite-decoy.txt")
        // A macOS housekeeping dot-directory, as would show up on a real
        // external volume — any dot-directory must be skipped, not just
        // `.astro_tool`.
        try makeFile(".fseventsd/junk.txt")

        return root
    }
}
