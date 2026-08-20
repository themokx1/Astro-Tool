@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Pure builder tests -- no `Database`/`AstroConfig` fixture anywhere, since
/// `NightRibbonBuilder.build` takes every `Date` it needs already resolved
/// (a fixture `SessionTimeline` for captures/gaps, a fixture `SkyWindows`
/// for the sky bands). See `NightRibbonBuilder.swift`'s own doc comment for
/// why: gap-threshold logic itself belongs to `SessionTimeline.timeline`
/// (`config.stats.gapThresholdSeconds`, else 3x median nominal exptime) --
/// this builder only reads `timeline.gaps` verbatim, so these fixtures
/// simply hand it gaps `SessionTimeline` would already have decided on.
@Suite("NightRibbonBuilder")
struct NightRibbonBuilderTests {
    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    private func isoZ(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    // MARK: - Capture / gap alternation

    @Test("A single gap splits the capture window into capture-gap-capture, in chronological order")
    func capturesAndGapsAlternateAroundOneGap() throws {
        let start = try date("2026-08-08T21:52:00Z")
        let gapStart = try date("2026-08-08T23:04:00Z")
        let gapEnd = try date("2026-08-08T23:27:00Z")
        let end = try date("2026-08-09T00:11:00Z")

        let timeline = SessionTimeline(
            target: "IC1396", date: "2026-08-08",
            windowStart: isoZ(start), windowEnd: isoZ(end),
            windowSeconds: end.timeIntervalSince(start),
            integrationSeconds: 3600,
            gaps: [SessionTimeline.Gap(start: isoZ(gapStart), end: isoZ(gapEnd), seconds: gapEnd.timeIntervalSince(gapStart))]
        )

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: .init())

        #expect(ribbon.events.map(\.kind) == [.capture, .gap, .capture])
        #expect(ribbon.events.map(\.start) == [start, gapStart, gapEnd])
        #expect(ribbon.events.map(\.end) == [gapStart, gapEnd, end])
    }

    @Test("Several gaps produce capture-gap pairs alternating chronologically, with a trailing capture")
    func multipleGapsAlternateInOrder() throws {
        let start = try date("2026-08-08T20:00:00Z")
        let gap1Start = try date("2026-08-08T21:00:00Z")
        let gap1End = try date("2026-08-08T21:10:00Z")
        let gap2Start = try date("2026-08-08T22:00:00Z")
        let gap2End = try date("2026-08-08T22:05:00Z")
        let end = try date("2026-08-08T23:00:00Z")

        let timeline = SessionTimeline(
            target: "M31", date: "2026-08-08",
            windowStart: isoZ(start), windowEnd: isoZ(end),
            windowSeconds: end.timeIntervalSince(start),
            integrationSeconds: 7200,
            // Handed to the builder out of order on purpose -- it must sort
            // by `start` itself before walking, same as
            // `NightReport.renderTimelineBar` already does.
            gaps: [
                SessionTimeline.Gap(start: isoZ(gap2Start), end: isoZ(gap2End), seconds: gap2End.timeIntervalSince(gap2Start)),
                SessionTimeline.Gap(start: isoZ(gap1Start), end: isoZ(gap1End), seconds: gap1End.timeIntervalSince(gap1Start)),
            ]
        )

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: .init())

        #expect(ribbon.events.map(\.kind) == [.capture, .gap, .capture, .gap, .capture])
        #expect(ribbon.events.map(\.start) == [start, gap1Start, gap1End, gap2Start, gap2End])
        #expect(ribbon.events.map(\.end) == [gap1Start, gap1End, gap2Start, gap2End, end])
    }

    @Test("A gap flush against the window edge produces no zero-width leading/trailing capture event")
    func gapAtWindowEdgeOmitsDegenerateCapture() throws {
        let start = try date("2026-08-08T20:00:00Z")
        let end = try date("2026-08-08T21:00:00Z")

        let timeline = SessionTimeline(
            target: "M31", date: "2026-08-08",
            windowStart: isoZ(start), windowEnd: isoZ(end),
            windowSeconds: end.timeIntervalSince(start),
            integrationSeconds: 1800,
            // The gap starts exactly at the window start -- no capture
            // happened before it, so there must be no leading zero-width
            // `.capture` event.
            gaps: [SessionTimeline.Gap(start: isoZ(start), end: isoZ(end), seconds: end.timeIntervalSince(start))]
        )

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: .init())

        #expect(ribbon.events.map(\.kind) == [.gap])
    }

    // MARK: - No DATE-OBS -> no capture band

    @Test("A timeline with no resolvable window (no usable light had a parseable DATE-OBS) produces no capture/gap events")
    func noWindowProducesNoCaptureBand() throws {
        // `SessionTimeline.timeline` itself returns `windowStart`/`windowEnd`
        // as `nil` in exactly this case (the DSLR/no-DATE-OBS session) --
        // reproduced here directly rather than via a DB fixture.
        let timeline = SessionTimeline(target: "M31", date: "2026-08-08", integrationSeconds: 900)

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: .init())

        #expect(ribbon.events.isEmpty)
    }

    // MARK: - Sky bands drop honestly when unresolved

    @Test("An unresolved sky window (no site/coordinates) drops only that band, not the others")
    func unresolvedSkyWindowsDropIndependently() throws {
        let start = try date("2026-08-08T21:00:00Z")
        let end = try date("2026-08-08T22:00:00Z")
        let timeline = SessionTimeline(
            target: "M31", date: "2026-08-08",
            windowStart: isoZ(start), windowEnd: isoZ(end),
            windowSeconds: end.timeIntervalSince(start), integrationSeconds: 3600
        )

        // Only the twilight window resolved (site known, target coordinate
        // unresolved -- e.g. a plate-solve-less session) -- Moon/target
        // bands must be absent, not defaulted to anything.
        let twilightStart = try date("2026-08-08T20:00:00Z")
        let twilightEnd = try date("2026-08-08T23:00:00Z")
        let sky = NightRibbonBuilder.SkyWindows(
            astronomicalTwilight: DateInterval(start: twilightStart, end: twilightEnd)
        )

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: sky)

        #expect(ribbon.events.contains { $0.kind == .astronomicalTwilight })
        #expect(!ribbon.events.contains { $0.kind == .moon })
        #expect(!ribbon.events.contains { $0.kind == .targetVisibility })
        #expect(ribbon.events.contains { $0.kind == .capture })
    }

    @Test("No site/coordinates at all drops every sky band, keeping only capture/gap")
    func noSiteDataDropsAllSkyBands() throws {
        let start = try date("2026-08-08T21:00:00Z")
        let end = try date("2026-08-08T22:00:00Z")
        let timeline = SessionTimeline(
            target: "M31", date: "2026-08-08",
            windowStart: isoZ(start), windowEnd: isoZ(end),
            windowSeconds: end.timeIntervalSince(start), integrationSeconds: 3600
        )

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: .init())

        #expect(ribbon.events.allSatisfy { $0.kind == .capture || $0.kind == .gap })
        #expect(!ribbon.events.isEmpty)
    }

    // MARK: - Band clipping to the night window

    @Test("Moon-up and target-visible windows wider than the twilight window are clipped to it")
    func skyBandsClipToTwilightWindow() throws {
        let twilightStart = try date("2026-08-08T20:00:00Z")
        let twilightEnd = try date("2026-08-09T04:00:00Z")
        // The Moon is up well before dusk and well after dawn -- the
        // rendered band must never extend past the night window itself.
        let moonStart = try date("2026-08-08T18:00:00Z")
        let moonEnd = try date("2026-08-09T06:00:00Z")
        // The target rises mid-twilight and is still up after dawn.
        let targetStart = try date("2026-08-08T22:00:00Z")
        let targetEnd = try date("2026-08-09T08:00:00Z")

        let timeline = SessionTimeline(target: "M31", date: "2026-08-08", integrationSeconds: 0)
        let sky = NightRibbonBuilder.SkyWindows(
            astronomicalTwilight: DateInterval(start: twilightStart, end: twilightEnd),
            moonUp: DateInterval(start: moonStart, end: moonEnd),
            targetVisible: DateInterval(start: targetStart, end: targetEnd)
        )

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: sky)

        let moon = try #require(ribbon.events.first { $0.kind == .moon })
        #expect(moon.start == twilightStart)
        #expect(moon.end == twilightEnd)

        let target = try #require(ribbon.events.first { $0.kind == .targetVisibility })
        #expect(target.start == targetStart)
        #expect(target.end == twilightEnd)
    }

    @Test("A sky window entirely outside the night window is dropped rather than clipped to nothing")
    func skyBandEntirelyOutsideNightWindowIsDropped() throws {
        let twilightStart = try date("2026-08-08T20:00:00Z")
        let twilightEnd = try date("2026-08-09T04:00:00Z")
        // The Moon sets well before dusk even begins -- no overlap at all.
        let moonStart = try date("2026-08-08T10:00:00Z")
        let moonEnd = try date("2026-08-08T18:00:00Z")

        let timeline = SessionTimeline(target: "M31", date: "2026-08-08", integrationSeconds: 0)
        let sky = NightRibbonBuilder.SkyWindows(
            astronomicalTwilight: DateInterval(start: twilightStart, end: twilightEnd),
            moonUp: DateInterval(start: moonStart, end: moonEnd)
        )

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: sky)

        #expect(!ribbon.events.contains { $0.kind == .moon })
        #expect(ribbon.events.contains { $0.kind == .astronomicalTwilight })
    }

    @Test("With no twilight resolved, sky bands clip to the capture window instead")
    func skyBandsClipToCaptureWindowWhenTwilightUnresolved() throws {
        let captureStart = try date("2026-08-08T21:00:00Z")
        let captureEnd = try date("2026-08-08T23:00:00Z")
        let timeline = SessionTimeline(
            target: "M31", date: "2026-08-08",
            windowStart: isoZ(captureStart), windowEnd: isoZ(captureEnd),
            windowSeconds: captureEnd.timeIntervalSince(captureStart), integrationSeconds: 7200
        )
        // Moon window wider than the capture window on both sides.
        let moonStart = try date("2026-08-08T19:00:00Z")
        let moonEnd = try date("2026-08-09T01:00:00Z")
        let sky = NightRibbonBuilder.SkyWindows(moonUp: DateInterval(start: moonStart, end: moonEnd))

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: sky)

        let moon = try #require(ribbon.events.first { $0.kind == .moon })
        #expect(moon.start == captureStart)
        #expect(moon.end == captureEnd)
    }

    // MARK: - Ordering

    @Test("Events from every band come back chronologically ordered, matching NightRibbonModel's own sort")
    func eventsAcrossAllBandsAreChronologicallyOrdered() throws {
        let twilightStart = try date("2026-08-08T20:00:00Z")
        let twilightEnd = try date("2026-08-09T04:00:00Z")
        let captureStart = try date("2026-08-08T21:00:00Z")
        let captureEnd = try date("2026-08-09T00:00:00Z")
        let gapStart = try date("2026-08-08T22:00:00Z")
        let gapEnd = try date("2026-08-08T22:15:00Z")

        let timeline = SessionTimeline(
            target: "M31", date: "2026-08-08",
            windowStart: isoZ(captureStart), windowEnd: isoZ(captureEnd),
            windowSeconds: captureEnd.timeIntervalSince(captureStart), integrationSeconds: 7200,
            gaps: [SessionTimeline.Gap(start: isoZ(gapStart), end: isoZ(gapEnd), seconds: gapEnd.timeIntervalSince(gapStart))]
        )
        let sky = NightRibbonBuilder.SkyWindows(astronomicalTwilight: DateInterval(start: twilightStart, end: twilightEnd))

        let ribbon = try NightRibbonBuilder.build(timeline: timeline, sky: sky)

        let starts = ribbon.events.map(\.start)
        #expect(starts == starts.sorted())
        #expect(ribbon.events.first?.kind == .astronomicalTwilight)
    }
}
