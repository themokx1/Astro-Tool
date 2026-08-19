import AstroCore
import Foundation

/// Turns one night's already-loaded `SessionTimeline` plus independently
/// resolved sky-geometry windows into a `NightRibbonModel` -- the event
/// ribbon model that has had zero UI/builder consumers since it landed (see
/// `NightRibbonModel.swift`'s own file). Pure and DB-free: every `Date` this
/// touches is handed in already resolved, so it is exhaustively testable
/// with plain fixture values, no `Database`/`AstroConfig` fixture required.
/// `NightRibbonQuery` (same directory) is the thin, DB-touching adapter that
/// resolves `SkyWindows` and calls this.
///
/// Capture/gap events are derived from `timeline.windowStart`/`windowEnd`/
/// `gaps` alone -- the SAME aggregate `SessionTimeline.timeline` already
/// computed from the session's usable lights' `DATE-OBS` (via
/// `SessionTimeline.parseDateObs`) for `NightReportQuery.Result.timeline`.
/// This builder never re-scans frames or re-parses a single `DATE-OBS`
/// itself; it only walks the gap list, porting the exact alternating-
/// segment algorithm `NightReport.renderTimelineBar` already uses for the
/// HTML report's own CSS timeline bar (`Sources/AstroCore/Export/
/// NightReport.swift`), so the ribbon's capture/gap spans and that bar's
/// spans can never silently disagree.
///
/// Gap-threshold rule: NOT reimplemented here. A gap is whatever
/// `SessionTimeline.timeline` already decided is a gap -- silent time
/// between two consecutive frames' start/end exceeding
/// `config.stats.gapThresholdSeconds` when the user has set one, else 3x
/// the median NOMINAL exposure across the session's timed frames (see
/// `SessionTimeline.gapThreshold`'s own doc comment). Reusing that single
/// source of truth, rather than picking a second fixed number (e.g. a flat
/// 5 minutes) here, keeps the ribbon's gap markers and the report's
/// "Idővonal" gap list always in agreement.
public enum NightRibbonBuilder {
    /// One optional `[start, end]` window per sky band -- `nil` whenever
    /// that band's own prerequisite could not be resolved: site coordinates
    /// for `astronomicalTwilight`/`moonUp`, site AND target coordinates for
    /// `targetVisible`. Dropping the band is the honest behavior a missing
    /// window must produce -- never a guess, never "assume all night".
    public struct SkyWindows: Sendable, Equatable {
        public var astronomicalTwilight: DateInterval?
        public var moonUp: DateInterval?
        public var targetVisible: DateInterval?

        public init(
            astronomicalTwilight: DateInterval? = nil,
            moonUp: DateInterval? = nil,
            targetVisible: DateInterval? = nil
        ) {
            self.astronomicalTwilight = astronomicalTwilight
            self.moonUp = moonUp
            self.targetVisible = targetVisible
        }
    }

    /// Builds the ribbon. `astronomicalTwilight` is added as-is (it defines
    /// the ribbon's own primary night window); `moonUp`/`targetVisible` are
    /// each clipped to that night window (or, absent any twilight, to the
    /// capture window) before becoming events, so a sky-track sample that
    /// runs wider than the night itself (e.g. the Moon still up well past
    /// dawn) never paints a band that visually overruns the ribbon's own
    /// extent. A band clipped down to nothing (no overlap with the night
    /// window at all) is dropped, same honesty rule as an unresolved
    /// window.
    ///
    /// Throws only if `NightRibbonModel`'s own interval invariant is
    /// somehow violated -- never in practice here, since every interval
    /// this function constructs is either a caller-supplied `DateInterval`
    /// (valid by that type's own construction, `start <= end`) or a clipped
    /// subset of one.
    public static func build(timeline: SessionTimeline, sky: SkyWindows) throws -> NightRibbonModel {
        var events: [NightRibbonEvent] = []

        let window = nightWindow(timeline: timeline, twilight: sky.astronomicalTwilight)

        if let twilight = sky.astronomicalTwilight {
            events.append(NightRibbonEvent(
                id: UUID(), start: twilight.start, end: twilight.end,
                kind: .astronomicalTwilight, label: "Astronomical twilight"
            ))
        }
        if let moonUp = sky.moonUp, let clipped = clip(moonUp, to: window) {
            events.append(NightRibbonEvent(
                id: UUID(), start: clipped.start, end: clipped.end,
                kind: .moon, label: "Moon above horizon"
            ))
        }
        if let targetVisible = sky.targetVisible, let clipped = clip(targetVisible, to: window) {
            events.append(NightRibbonEvent(
                id: UUID(), start: clipped.start, end: clipped.end,
                kind: .targetVisibility, label: "Target above horizon"
            ))
        }
        events += captureEvents(timeline: timeline)

        return try NightRibbonModel(events: events)
    }

    // MARK: - Night window

    /// The ribbon's own clipping bound: the union of the twilight window (if
    /// resolved) and the capture window (if any frame had a parseable
    /// `DATE-OBS`) -- whichever of the two is present, or their outer span
    /// when both are. `nil` only when neither resolved at all (no site data
    /// AND no parseable capture timestamps), in which case `moonUp`/
    /// `targetVisible` are added unclipped rather than dropped outright --
    /// an edge case that in practice never arises, since both bands already
    /// require the same site resolution `astronomicalTwilight` itself
    /// needs.
    private static func nightWindow(timeline: SessionTimeline, twilight: DateInterval?) -> DateInterval? {
        let capture = captureWindow(timeline: timeline)
        switch (twilight, capture) {
        case let (t?, c?):
            return DateInterval(start: min(t.start, c.start), end: max(t.end, c.end))
        case let (t?, nil):
            return t
        case let (nil, c?):
            return c
        case (nil, nil):
            return nil
        }
    }

    private static func captureWindow(timeline: SessionTimeline) -> DateInterval? {
        guard let startISO = timeline.windowStart, let endISO = timeline.windowEnd,
              let start = parseISOZ(startISO), let end = parseISOZ(endISO), end >= start
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// Intersects `window` with `bound`. `nil` (drop the band) when `bound`
    /// exists but the intersection is empty or degenerate (zero-width);
    /// `window` unchanged when there is no `bound` to clip against at all.
    private static func clip(_ window: DateInterval, to bound: DateInterval?) -> DateInterval? {
        guard let bound else { return window }
        let start = max(window.start, bound.start)
        let end = min(window.end, bound.end)
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    // MARK: - Capture / gap events

    /// Ports `NightReport.renderTimelineBar`'s exact alternating-segment
    /// walk (`Sources/AstroCore/Export/NightReport.swift`) from CSS-bar
    /// percentages to `NightRibbonEvent`s: walk `timeline.gaps` in
    /// chronological order, emitting the "active" (capture) span before
    /// each gap and a trailing active span from the last gap's end (or the
    /// window start, if there were no gaps at all) to the window end. `[]`
    /// when the window itself can't be resolved -- no usable light had a
    /// parseable `DATE-OBS` (e.g. DSLR frames whose EXIF didn't parse) --
    /// the honest "keret-időbélyegek nem elérhetők" case the view surfaces.
    private static func captureEvents(timeline: SessionTimeline) -> [NightRibbonEvent] {
        guard let startISO = timeline.windowStart, let endISO = timeline.windowEnd,
              let start = parseISOZ(startISO), let end = parseISOZ(endISO), end > start
        else { return [] }

        var events: [NightRibbonEvent] = []
        var cursor = start
        for gap in timeline.gaps.sorted(by: { $0.start < $1.start }) {
            guard let gapStart = parseISOZ(gap.start), let gapEnd = parseISOZ(gap.end),
                  gapStart >= cursor, gapEnd >= gapStart
            else { continue }
            if gapStart > cursor {
                events.append(NightRibbonEvent(
                    id: UUID(), start: cursor, end: gapStart, kind: .capture, label: "Capture"
                ))
            }
            events.append(NightRibbonEvent(
                id: UUID(), start: gapStart, end: gapEnd, kind: .gap, label: "Gap"
            ))
            cursor = gapEnd
        }
        if end > cursor {
            events.append(NightRibbonEvent(
                id: UUID(), start: cursor, end: end, kind: .capture, label: "Capture"
            ))
        }
        return events
    }

    // MARK: - ISO parsing

    /// Round-trips the exact `"yyyy-MM-dd'T'HH:mm:ss'Z'"` shape
    /// `SessionTimeline.timeline`'s own `windowStart`/`windowEnd`/`gaps` are
    /// formatted in -- the same fixed-format parser `NightReport.parseISOZ`
    /// keeps privately for the identical reason (a plain round-trip of one
    /// known shape, not a general ISO 8601 parser).
    private static func parseISOZ(_ raw: String) -> Date? {
        isoZFormatter.date(from: raw)
    }

    private static let isoZFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()
}
