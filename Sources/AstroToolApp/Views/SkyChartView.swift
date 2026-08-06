import AstroCore
import Charts
import SwiftUI

/// `Planner.plan`'s own `minAltitudeDeg` default
/// (`Sources/AstroCore/Sky/Planner.swift`). `AstroConfig` has no per-user
/// override for it yet, and every `Planner.plan(...)` call site in
/// `AppState` relies on that same default -- both `TonightPage`'s selected-
/// row chart panel and `OverviewSegment`'s "Ma esti ív" card need their
/// min-altitude rule to sit at the SAME value the plan they're showing was
/// actually computed against, so this lives here once rather than as two
/// independently-hardcoded literals that could silently drift apart.
let plannerDefaultMinAltitudeDeg: Double = 30

/// Altitude-over-the-night chart -- the "industry-standard" visual observing-
/// planner view (R10-B2): a target's altitude curve across tonight's (or a
/// calendar-selected night's) dark window, the Moon's altitude for
/// comparison, twilight shading, a minimum-altitude guide line, and (for the
/// actually-current night only) a "now" marker.
///
/// Pure presentation: every number drawn here is handed in by the caller --
/// `SkyTrack` (R10-A2) computes the tracks/markers off a resolved site
/// coordinate, this view never touches `AppState`/the DB. That's what makes
/// it reusable as-is between `TonightPage`'s selected-row panel and the
/// target Áttekintés segment's "Ma esti ív" card.
struct SkyChartView: View {
    let targetName: String
    let targetTrack: [SkyTrackPoint]
    let moonTrack: [SkyTrackPoint]
    let markers: NightWindowMarkers
    let minAltitudeDeg: Double
    /// Drives the vertical "now" rule -- only meaningful (and only drawn)
    /// for the actually-current night; a calendar-selected past/future night
    /// has no "now" position on its own altitude axis.
    let isTonight: Bool
    /// The night this track was sampled for. Only consulted as a fallback
    /// sampling window when both tracks are empty (see `xDomain`) so the
    /// chart still renders a sane frame rather than an empty one with no
    /// axis at all -- callers aren't expected to hit this in practice
    /// (`SkyTrack.altitudeTrack`/`moonAltitudeTrack` are documented as
    /// "never empty"), but this view must not crash if they do.
    let nightOf: Date
    /// Shown next to "Hold" in the legend row when provided -- `nil` skips
    /// the suffix (callers without a `TargetPlan.moonIlluminationPercent`
    /// handy, e.g. a bare coordinate with no plan computed yet, still get a
    /// usable legend).
    var moonIlluminationPercent: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(targetName)
                .font(.subheadline.bold())
                .lineLimit(1)

            Chart {
                nauticalBand
                astroBand
                minAltitudeRule
                moonLine
                targetLine
                nowRule
            }
            .chartLegend(.hidden)
            .chartYScale(domain: 0...90)
            .chartXScale(domain: xDomain)
            .chartYAxisLabel("Magasság (°)")
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { value in
                    AxisGridLine()
                    AxisTick()
                    if let date = value.as(Date.self) {
                        AxisValueLabel(Self.hourFormatter.string(from: date))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 30.0, 60.0, 90.0])
            }
            .frame(height: 200)

            legendRow
        }
    }

    // MARK: - Marks

    @ChartContentBuilder
    private var targetLine: some ChartContent {
        ForEach(targetTrack, id: \.time) { point in
            LineMark(
                x: .value("Idő", point.time),
                y: .value("Magasság", point.altitudeDeg)
            )
        }
        .foregroundStyle(Color.accentColor)
        .lineStyle(StrokeStyle(lineWidth: 2.5))
    }

    @ChartContentBuilder
    private var moonLine: some ChartContent {
        ForEach(moonTrack, id: \.time) { point in
            LineMark(
                x: .value("Idő", point.time),
                y: .value("Hold magassága", point.altitudeDeg)
            )
        }
        .foregroundStyle(Color.gray)
        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
    }

    @ChartContentBuilder
    private var minAltitudeRule: some ChartContent {
        RuleMark(y: .value("Min. magasság", minAltitudeDeg))
            .foregroundStyle(.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    @ChartContentBuilder
    private var nowRule: some ChartContent {
        if isTonight, xDomain.contains(Date()) {
            RuleMark(x: .value("Most", Date()))
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
        }
    }

    /// Wider (-12°) band, subtle tint -- drawn alone (per
    /// `NightWindowMarkers`'s own nil-together rules) whenever the night
    /// never reaches true astronomical darkness but does reach nautical
    /// twilight.
    @ChartContentBuilder
    private var nauticalBand: some ChartContent {
        if let dusk = markers.nauticalDuskUTC, let dawn = markers.nauticalDawnUTC {
            RectangleMark(
                xStart: .value("Kezdet", dusk),
                xEnd: .value("Vég", dawn),
                yStart: .value("Alsó", 0.0),
                yEnd: .value("Felső", 90.0)
            )
            .foregroundStyle(Color.indigo.opacity(0.10))
        }
    }

    /// Narrower (-18°), stronger tint -- only when the night actually gets
    /// there (both dates are non-nil together, per `NightWindowMarkers`).
    @ChartContentBuilder
    private var astroBand: some ChartContent {
        if let dusk = markers.astroDuskUTC, let dawn = markers.astroDawnUTC {
            RectangleMark(
                xStart: .value("Kezdet", dusk),
                xEnd: .value("Vég", dawn),
                yStart: .value("Alsó", 0.0),
                yEnd: .value("Felső", 90.0)
            )
            .foregroundStyle(Color.indigo.opacity(0.22))
        }
    }

    // MARK: - Legend

    /// Textual legend using dash characters to echo each line's own style
    /// (solid "—" for the target, "- -" for the Moon's dashed style) rather
    /// than a second drawing surface -- cheap, and reads fine at caption
    /// size.
    private var legendRow: some View {
        HStack(spacing: 4) {
            Text("—").foregroundStyle(Color.accentColor).bold()
            Text("célpont").foregroundStyle(.secondary)
            Text("·").foregroundStyle(.secondary)
            Text("- -").foregroundStyle(.gray).bold()
            Text(moonLegendLabel).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.caption2)
    }

    private var moonLegendLabel: String {
        guard let percent = moonIlluminationPercent else { return "Hold" }
        return "Hold (\(TDFormat.percent(percent)))"
    }

    // MARK: - X domain

    /// The window both tracks were sampled across (see `SkyTrack`'s own doc
    /// comment) -- read directly off the data rather than re-derived, so
    /// this view never needs the site coordinate its caller already used to
    /// build the tracks. Falls back to a +/-12h span around `nightOf` only
    /// when BOTH tracks are empty.
    private var xDomain: ClosedRange<Date> {
        if let first = targetTrack.first?.time, let last = targetTrack.last?.time, first <= last {
            return first...last
        }
        if let first = moonTrack.first?.time, let last = moonTrack.last?.time, first <= last {
            return first...last
        }
        return nightOf.addingTimeInterval(-12 * 3600)...nightOf.addingTimeInterval(12 * 3600)
    }

    // MARK: - Formatting

    /// "HH" only -- deliberately `en_US_POSIX`, not `hu_HU`, so the axis
    /// reads the same 24-hour numeral regardless of the user's system
    /// locale (same reasoning as `TonightPage.isoDateFormatter`).
    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH"
        return formatter
    }()
}
