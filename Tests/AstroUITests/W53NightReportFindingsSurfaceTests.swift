import Foundation
import Testing

/// W5-3 (owner pixel review, 2026-08-24 IC 4604 night): literal source-text
/// pins for the findings this ticket fixed inside `NightWorkspaceView.swift`/
/// `FrameBlinkReview.swift` -- same "surface" convention
/// `V2PolishSurfaceTests`/`HelpSurfaceTests` already establish (a wiring/
/// vocabulary contract, not a rendered-layout one), kept in its own file
/// rather than added to `V2PolishSurfaceTests.swift` since that file is
/// shared across every concurrent V2 workstream and this ticket's scope is
/// deliberately narrow (`NightWorkspaceView.swift`, `FrameBlinkReview.swift`,
/// `NightReportQuery.swift` -- see the ticket's own file list).
@Suite("W5-3 night-report pixel-review findings")
struct W53NightReportFindingsSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Source with every `//` line comment stripped, so a doc comment that
    /// NAMES the old code it replaced (e.g. this very file's own doc
    /// comments, which quote `AstroTokens.Color.edge.opacity` to explain
    /// what was removed) can never trip a "must not contain" scan below.
    /// Copied from `V2PolishSurfaceTests.removingLineComments` (same
    /// string/comment-aware algorithm) rather than shared, since that type
    /// keeps it `private` and this suite is deliberately kept out of that
    /// shared file -- see this suite's own doc comment for why.
    private static func removingLineComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var i = source.startIndex
        var inLineComment = false
        var inString = false
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            if inLineComment {
                if c == "\n" { inLineComment = false; result.append(c) }
                i = next
                continue
            }
            if inString {
                result.append(c)
                if c == "\\", next < source.endIndex {
                    result.append(source[next])
                    i = source.index(after: next)
                    continue
                }
                if c == "\"" { inString = false }
                i = next
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                i = next
                continue
            }
            if c == "/", next < source.endIndex, source[next] == "/" {
                inLineComment = true
                i = source.index(after: next)
                continue
            }
            result.append(c)
            i = next
        }
        return result
    }

    // MARK: - Finding 3: the Triage hero card must not render text through
    // the numeric `astroDataHero()` style.

    /// `MetricCard.value`'s own doc comment (`WorkspaceComponents.swift`)
    /// says it is "almost always a formatted number/duration, never a
    /// phrase to translate" -- the Triage card's value
    /// (`row.triageState.localizedText`, e.g. "Needs review") is exactly
    /// that one exception, and rendering it through `MetricCard`'s 30pt
    /// monospaced `astroDataHero()` style sprawled the text across the
    /// card. Pins the fix (`TextMetricCard`, a file-local twin with a
    /// text-appropriate value style) without touching the shared
    /// `MetricCard` component every OTHER workspace's numeric hero cards
    /// still use.
    @Test("Night workspace's Triage hero card uses a text-appropriate value style, not MetricCard's numeric one")
    func triageHeroCardUsesTextStyleNotNumericHero() throws {
        let source = Self.removingLineComments(try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift"))

        #expect(
            source.contains("TextMetricCard(title: \"Triage\""),
            "Triage card must route through a text-appropriate value style, not MetricCard's astroDataHero()"
        )
        // A plain `.contains("MetricCard(title: \"Triage\"")` would also
        // match INSIDE `TextMetricCard(title: "Triage"` (it ends with
        // exactly that substring) -- anchor on a call site's leading
        // whitespace/`(` so only a BARE `MetricCard(...)` counts, never the
        // file-local `TextMetricCard(...)` twin.
        #expect(
            !source.contains(" MetricCard(title: \"Triage\"") && !source.contains("(MetricCard(title: \"Triage\""),
            "Triage card must not go back to MetricCard's numeric astroDataHero() style"
        )
        // The two genuinely numeric/duration cards next to it must keep
        // using the shared numeric component -- this fix must not regress
        // them onto the file-local text twin instead.
        #expect(source.contains(" MetricCard(title: \"Integration\""))
        #expect(source.contains(" MetricCard(title: \"Series\""))
        // `TextMetricCard` itself must not adopt the numeric hero style --
        // that would silently undo the whole point of introducing it.
        let twinRange = try #require(source.range(of: "private struct TextMetricCard"))
        let twinBody = source[twinRange.lowerBound...]
        #expect(!twinBody.contains(".astroDataHero()"))
    }

    // MARK: - Finding 2: the Minőség/Quality section's exposure-advice
    // fallback must point at the in-app action, not a terminal command.

    /// `ExposureAdvisor.notAvailableReason` (`AstroCore/Stats/
    /// ExposureAdvisor.swift`) ends with a CLI-era suggestion this app has
    /// no terminal for. Pins that `NightWorkspaceView` no longer
    /// interpolates that raw reason straight into the rendered `Text` (the
    /// old-HTML-report vocabulary bug) and instead routes it through a
    /// substitution that swaps the CLI suggestion for the header's own
    /// "Rate Frames" action.
    @Test("Night workspace's exposure-advice fallback does not surface astrotool's raw CLI suggestion verbatim")
    func exposureAdviceDoesNotQuoteCLICommand() throws {
        let source = Self.removingLineComments(try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift"))

        #expect(
            !source.contains("\\(reason)"),
            "the raw AstroCore reason string must be rewritten before display, not interpolated as-is"
        )
        #expect(source.contains("exposureAdviceReasonText(reason)"))
        #expect(source.contains("Rate Frames"), "the substitute text must point at the in-app action's own label")
        // The CLI suffix this substitution targets must stay byte-for-byte
        // in sync with `ExposureAdvisor.swift`'s own literal -- if that
        // source string ever changes, this substitution silently stops
        // firing and the raw CLI text reappears on screen.
        let exposureAdvisorSource = try contents("Sources/AstroCore/Stats/ExposureAdvisor.swift")
        #expect(exposureAdvisorSource.contains(" — futtasd újra: astrotool rate"))
        #expect(source.contains("\" — futtasd újra: astrotool rate\""))
    }

    /// W6-E item 6 (live pixel review): `ExposureAdvisor`'s OTHER CLI
    /// branch -- "nincs szenzor-profil — futtasd: astrotool sensor
    /// --measure" -- got the exact same substitution treatment as the
    /// `astrotool rate` case above, PLUS a real navigable "Sensor
    /// Profiles…" button (unlike "Rate Frames", Sensor Profiles has no
    /// button already on this page to point at in prose alone).
    @Test("Night workspace's sensor-profile exposure-advice fallback points at the Sensor Profiles page, with a real button")
    func exposureAdviceSensorProfileFallbackHasARealButton() throws {
        let source = Self.removingLineComments(try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift"))

        #expect(source.contains("exposureAdviceSensorCLISuffix"))
        #expect(source.contains("Sensor Profiles"), "the substitute text/button must name the real in-app page")
        #expect(source.contains("openSensorProfiles"), "must accept a real navigation closure, not just rephrase the text")
        #expect(source.contains("Button(\"Sensor Profiles…\", action: openSensorProfiles)"))

        // The CLI suffix this substitution targets must stay byte-for-byte
        // in sync with ExposureAdvisor.swift's own literal.
        let exposureAdvisorSource = try contents("Sources/AstroCore/Stats/ExposureAdvisor.swift")
        #expect(exposureAdvisorSource.contains("nincs szenzor-profil — futtasd: astrotool sensor --measure"))
        #expect(source.contains("\" — futtasd: astrotool sensor --measure\""))
    }

    // MARK: - Finding 4: FrameBlinkReview's stage backdrop must darken in
    // both appearances, never invert in dark mode.

    /// `AstroTokens.Color.edge` (`AstroTokens.swift`) is deliberately
    /// LIGHTER than `ground`/`surface` in dark appearance (a hairline needs
    /// to read against a near-black backdrop there) -- painting it as a
    /// translucent film behind the review stage therefore BRIGHTENED the
    /// stage in dark mode instead of dimming it, backwards from a photo
    /// mat, in exactly the appearance that stage spends the most real
    /// review time in. Pins the fix: an appearance-pinned true-black fill
    /// (via the same `AstroTokens.Color.dynamic(dark:light:)` factory every
    /// other structural token is built from) that can only ever darken.
    @Test("FrameBlinkReview's preview stage backdrop darkens in both appearances, never AstroTokens.Color.edge")
    func blinkReviewStageBackdropIsAppearanceHonest() throws {
        let source = Self.removingLineComments(try contents("Sources/AstroUI/Features/Review/FrameBlinkReview.swift"))

        #expect(
            !source.contains("AstroTokens.Color.edge.opacity"),
            "the stage backdrop must not paint the edge token -- it is lighter than the backdrop in dark appearance"
        )
        #expect(
            source.contains("AstroTokens.Color.dynamic(dark: 0x000000, light: 0x000000)"),
            "the stage backdrop must be pinned to true black in BOTH appearances, so it only ever darkens"
        )
    }
}
