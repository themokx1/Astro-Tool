import Foundation

/// One canonical formatter per unit displayed anywhere in `AstroUI` -- spec
/// `docs/superpowers/specs/2026-08-16-archive-map-ux-redesign-design.md`
/// section 5.2, "Mértékegység-szabály" (the `P2` pattern's elimination).
///
/// Before this existed, the same `h:mm` duration split was hand-rolled with
/// `String(format: "%d:%02d", ...)` independently in six files (ten
/// duplicate definitions) across `Inspector/`, `Features/Home`,
/// `Features/Nights`, and `Features/Projects` -- fixing a rounding bug in
/// one of them would have silently left the others wrong, and no test could
/// ever have told two of those screens apart if they drifted. `%g`-formatted
/// gain/offset numbers were the same shape in miniature, duplicated across
/// `CalibrationView` and `SensorProfilesView`.
///
/// `Features/`/`Inspector/`/`Settings/` call sites must go through here
/// instead of building their own format string;
/// `V2PolishSurfaceTests.noHandRolledFormatting` gates this (see that
/// test's own doc comment for exactly what it does and does not cover,
/// including its one named exemption, `SiteSettingsStore.swift`, for a
/// locale reason).
public enum AstroFormat {
    /// Renders a duration as `h:mm h`, e.g. `12:40 h` -- always carries its
    /// unit so a bare number is never mistaken for something else. Matches
    /// the ten former hand-rolled call sites' own rounding exactly: the
    /// seconds value rounds to the nearest whole second first, then FLOORS
    /// to whole minutes -- a duration under a full minute reads as `0:00 h`,
    /// never blank or negative.
    ///
    /// Every former duplicate now calls this, including
    /// `NightsStore.swift`'s `NightRow.integrationSummary`, which was
    /// briefly exempted because routing it here reproducibly crashed
    /// `GlobalSearchStoreTests.searchesAcrossWorkflowObjects` with `freed
    /// pointer was not the last allocation`. That was never a fault in this
    /// function: the crash came from an `async` default argument emitted
    /// with two different async context sizes across translation units, and
    /// this edit only shifted the object file enough to flip which copy the
    /// linker kept. See `AsyncContextSizeGateTests` for the full account.
    public static func duration(seconds: Double) -> String {
        let totalMinutes = Int(seconds.rounded()) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%d:%02d h", hours, minutes)
    }

    /// Renders a byte count with the system's own file-size formatter --
    /// locale- and unit-aware (kB/MB/GB thresholds are the OS's own, not
    /// reimplemented here). This is a named pass-through, not a
    /// reimplementation: `ByteCountFormatter` cannot drift the way a
    /// hand-rolled format string can, so the point of this case is only to
    /// give `Features/` one obvious name to reach for instead of
    /// constructing a formatter inline.
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Renders an integer count with the user's locale grouping separator,
    /// e.g. `3 228` on a Hungarian system, `3,228` on a US one (spec 5.2).
    public static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Renders a coordinate in degrees to the four decimal places the site
    /// editor stores (`SiteSettingsStore`), locale-aware -- a Hungarian
    /// system renders a decimal comma, not a period. Read-only DISPLAY use
    /// only: `SiteSettingsStore`'s own editable draft text
    /// (`latitudeText`/`longitudeText`) deliberately keeps its existing
    /// locale-invariant `%.4f` formatting, because that string round-trips
    /// through `Double(_:)` on save, which requires a `.` decimal separator
    /// regardless of locale -- routing that specific field through this
    /// locale-aware formatter would break parsing on any non-English
    /// system. See that file's own call site and
    /// `V2PolishSurfaceTests.handRolledFormattingExemptFiles`.
    public static func degrees(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(4))))°"
    }

    /// Renders a unitless numeric coefficient (sensor gain, ADU offset) at
    /// its shortest exact decimal representation -- `100` stays `100`,
    /// `1.5` stays `1.5`. Matches the `%g` printf conversion the two former
    /// call sites (`CalibrationView.formattedNumber`,
    /// `SensorProfilesView.comboText`'s gain/offset text) each reimplemented
    /// by hand.
    public static func coefficient(_ value: Double) -> String {
        String(format: "%g", value)
    }

    /// Renders an Exif/FITS exposure length in seconds with its own unit,
    /// e.g. `"300 s"` for a light or `"0.0002 s"` for a bias -- the
    /// card-import wizard's Classify step group rows (W4-1b) read this
    /// value directly to tell a bias/flat/dark/light apart by eye, so it
    /// needs enough fractional precision to show a sub-millisecond bias
    /// exposure as something other than `"0 s"`.
    public static func exposureSeconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...4)))) s"
    }

    // MARK: - W5-1 (report sections)
    //
    // The in-app night/project report sections (`NightWorkspaceView`/
    // `ProjectWorkspaceView`) reuse the exact numbers the former HTML
    // reports (`NightReport`/`TargetReport`, `AstroCore`) computed, but
    // those two types format for an HTML string, not a SwiftUI `Text` --
    // each unit below gets its own home here instead, same "one canonical
    // formatter per unit" rule this file's own doc comment states.

    /// Renders a whole-number angle in degrees, e.g. `"34°"` -- altitude/
    /// separation readings, where sub-degree precision isn't meaningful
    /// (unlike `degrees(_:)`'s four-decimal SITE-COORDINATE precision).
    public static func wholeDegrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    /// Renders a rotation/position angle to one decimal degree, e.g. `"12.3°"`.
    public static func rotationDegrees(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))°"
    }

    /// Renders a fraction expressed on a 0...100 scale as a whole-number
    /// percentage, e.g. `"42%"`.
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Renders a median FWHM in arcseconds, e.g. `"2.34\""`.
    public static func fwhmArcsec(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2))))\""
    }

    /// Renders a median FWHM in pixels, e.g. `"3.10 px"` -- for a session
    /// with no resolvable pixel scale to convert to arcseconds.
    public static func fwhmPixels(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) px"
    }

    /// Renders a measured sky-background rate, e.g. `"0.0023 e⁻/s/arcsec²"`.
    public static func backgroundEPerSecArcsec2(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(4)))) e⁻/s/arcsec²"
    }

    /// Renders right ascension in sexagesimal hours/minutes/seconds, e.g.
    /// `"05h 34m 32.0s"` -- normalizes to `[0, 360)` degrees before the /15
    /// hour conversion. Locale-invariant on purpose: a coordinate string
    /// like this is copied/read, never typed into a locale-sensitive text
    /// field (contrast `degrees(_:)`'s own doc comment for the field that
    /// IS locale-sensitive and stays that way).
    public static func rightAscension(_ deg: Double) -> String {
        var normalized = deg.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let hours = normalized / 15.0
        let h = Int(hours)
        let minutesFull = (hours - Double(h)) * 60
        let m = Int(minutesFull)
        let s = (minutesFull - Double(m)) * 60
        return String(format: "%02dh %02dm %04.1fs", h, m, s)
    }

    /// Renders declination in signed sexagesimal degrees/arcminutes/
    /// arcseconds, e.g. `"+22° 00' 52.0\""`.
    public static func declination(_ deg: Double) -> String {
        let sign = deg < 0 ? "-" : "+"
        let absDeg = abs(deg)
        let d = Int(absDeg)
        let minutesFull = (absDeg - Double(d)) * 60
        let m = Int(minutesFull)
        let s = (minutesFull - Double(m)) * 60
        return "\(sign)\(String(format: "%02d° %02d' %04.1f\"", d, m, s))"
    }
}
