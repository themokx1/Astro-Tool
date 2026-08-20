import AstroUI
import Foundation
import Testing

/// Wave 2 Task 4: `AstroFormat`'s own contract tests. Written before the
/// implementation existed (all three failed to compile against a missing
/// type, then failed logically once a stub existed) -- see the wave's plan,
/// `docs/superpowers/plans/2026-08-16-visual-language-wave2.md`, Task 4 Step 1.
@Suite("AstroFormat")
struct AstroFormatTests {
    @Test("Durations render as h:mm with a unit, never bare")
    func durationCarriesItsUnit() {
        #expect(AstroFormat.duration(seconds: 45_600) == "12:40 h")
        #expect(AstroFormat.duration(seconds: 0) == "0:00 h")
        #expect(AstroFormat.duration(seconds: 59) == "0:00 h", "under a minute rounds down, it does not vanish")
    }

    @Test("Byte sizes are locale-formatted and never raw")
    func bytesAreFormatted() {
        #expect(AstroFormat.bytes(0) == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
    }

    @Test("Coordinates keep four decimals, the precision the site editor stores")
    func coordinatePrecision() {
        #expect(AstroFormat.degrees(47.4979) == "47,4979°" || AstroFormat.degrees(47.4979) == "47.4979°")
    }

    // MARK: Not in the plan's Step 1, but needed for the sweep: `coefficient`
    // unifies the two former `%g`-formatted call sites (`CalibrationView`'s
    // `formattedNumber`, `SensorProfilesView`'s gain/offset text) -- the
    // exact same duplicated-format shape the rest of this task fixes, just
    // not a `%d:%02d` duration.

    @Test("A whole-number coefficient renders without a trailing decimal")
    func coefficientDropsTrailingZero() {
        #expect(AstroFormat.coefficient(100) == "100")
    }

    @Test("A fractional coefficient keeps its shortest exact decimal")
    func coefficientKeepsFraction() {
        #expect(AstroFormat.coefficient(1.5) == "1.5")
    }
}
