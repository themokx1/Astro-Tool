import AstroCore
import Foundation

/// Pure data for one shareable "session card" -- expert ideation spec #4
/// ("one beautiful, dark-themed card per session ... rendered to PNG for
/// sharing"). Assembled ONLY from data the Night workspace already loads
/// (`NightRow`/`NightReportQuery.Result.quality`, the exact
/// `SessionQualitySummary` the Overview tab's own "Quality" section already
/// renders -- see `NightWorkspaceView.qualityStatItems`) -- no new number is
/// computed here, only reformatted for a fixed-size card layout instead of a
/// `ReportStatGrid` row.
///
/// Deliberately a plain `Sendable`/`Equatable` struct, not a view: keeps the
/// field-assembly logic (what shows, what falls back to the "not measured"
/// placeholder, what gates the export button) testable without constructing
/// any SwiftUI view or touching `ImageRenderer`, which cannot run headlessly
/// in a test target -- mirrors `ExportFileWriter`'s own "separate the pure
/// logic from the AppKit-only call" split (`Features/Exports/ExportMenu.swift`).
public struct SessionCardContent: Equatable, Sendable {
    /// Small corner mark on every card -- constant, not configurable: the
    /// point is that a shared PNG is recognizably from this app.
    public let appName: String
    /// The session's target/project display name, e.g. "IC 4604 Rho
    /// Ophiuchi" -- `NightReportQuery.Result.displayName`, the exact string
    /// the Overview tab's own header already resolves (project display name
    /// when a matching project exists, else the target folder name with
    /// underscores turned to spaces).
    public let targetName: String
    /// The session's raw date-dir string, e.g. "2026-08-17" -- `NightRow.
    /// date`/`NightReportQuery.Result.date`, verbatim, same as every other
    /// night-scoped surface in this app shows it (no re-parsing into a
    /// locale-formatted date here: `NightRow` never carries a `Date`, only
    /// this raw string).
    public let dateText: String
    /// Already `AstroFormat.duration`-formatted, e.g. "3:12 h" -- `NightRow.
    /// integrationSummary`, reused verbatim rather than re-summing seconds
    /// here.
    public let integrationText: String
    /// Median FWHM, arcsec preferred over pixels (same fallback order as
    /// `NightWorkspaceView.fwhmText`/`qualityStatItems`), already
    /// `AstroFormat`-formatted -- `Self.unmeasuredText` when the session has
    /// no rated frame with either value, NEVER "0" or a bare "–": a session
    /// nobody has scored yet has no FWHM, not a zero one.
    public let fwhmText: String
    /// Measured sky background rate in e-/s/arcsec^2, already `AstroFormat.
    /// backgroundEPerSecArcsec2`-formatted -- `Self.unmeasuredText` when no
    /// measured sensor bias level exists yet for this session's camera/gain/
    /// offset combo (see `SessionQualitySummary.backgroundEPerSecPerArcsec2`'s
    /// own doc comment for exactly why that can be `nil`).
    public let backgroundText: String
    /// Rated frame count backing the metrics above -- `0` for an unrated
    /// session, in which case `fwhmText`/`backgroundText` both read
    /// `Self.unmeasuredText` rather than a metric computed from zero frames.
    public let ratedFrameCount: Int
    /// A library-relative path `FrameThumbnailCell` can resolve against the
    /// open library's `rootURL`, for one representative frame from this
    /// session -- `nil` renders the card without a thumbnail rather than a
    /// broken image (spec: "graceful without it"). Nothing the Night
    /// workspace already loads (`NightRow`, `NightReportQuery.Result`) names
    /// an actual frame file today, so every call site passes `nil` for now;
    /// the field stays real (not deleted) so a future frame-picking query
    /// can wire a real path through without touching this type or its view.
    public let thumbnailRelativePath: String?

    public init(
        appName: String = "AstroTool",
        targetName: String,
        dateText: String,
        integrationText: String,
        fwhmText: String,
        backgroundText: String,
        ratedFrameCount: Int,
        thumbnailRelativePath: String?
    ) {
        self.appName = appName
        self.targetName = targetName
        self.dateText = dateText
        self.integrationText = integrationText
        self.fwhmText = fwhmText
        self.backgroundText = backgroundText
        self.ratedFrameCount = ratedFrameCount
        self.thumbnailRelativePath = thumbnailRelativePath
    }
}

/// Builds `SessionCardContent` from a session's already-loaded quality
/// summary, and gates whether the export action should even be offered.
public enum SessionCardAssembler {
    /// Honest placeholder for a metric no rated frame has contributed to
    /// yet -- never "0", which would misreport a real (if bad) measurement.
    /// Translated in `hu.lproj` to the owner's own words, "nincs mérve".
    public static let unmeasuredText = NSLocalizedString(
        "Not measured",
        bundle: .main,
        comment: "Session-card FWHM/background placeholder for a session with no rated frames yet (expert ideation spec #4)."
    )

    /// `true` only when the session has at least one rated frame -- the
    /// EXACT predicate `NightWorkspaceView`'s own Quality section already
    /// uses to decide between `ReportStatGrid` and its "No rated frames for
    /// this session." empty note (`report.quality.map { $0.frameCount > 0 }
    /// ?? false`), reused here so the export button's enabled state never
    /// drifts from what the Overview tab already shows for the same night.
    public static func isExportable(quality: SessionQualitySummary?) -> Bool {
        guard let quality else { return false }
        return quality.frameCount > 0
    }

    /// - Parameters:
    ///   - targetName: the session's display name -- callers pass
    ///     `NightReportQuery.Result.displayName`.
    ///   - dateText: the session's raw date-dir string -- callers pass
    ///     `NightRow.date`.
    ///   - integrationText: already `AstroFormat.duration`-formatted --
    ///     callers pass `NightRow.integrationSummary`.
    ///   - quality: the session's quality summary, or `nil` for a session
    ///     nothing has rated yet.
    ///   - thumbnailRelativePath: see `SessionCardContent`'s own doc comment.
    public static func content(
        targetName: String,
        dateText: String,
        integrationText: String,
        quality: SessionQualitySummary?,
        thumbnailRelativePath: String?
    ) -> SessionCardContent {
        SessionCardContent(
            targetName: targetName,
            dateText: dateText,
            integrationText: integrationText,
            fwhmText: fwhmText(quality),
            backgroundText: backgroundText(quality),
            ratedFrameCount: quality?.frameCount ?? 0,
            thumbnailRelativePath: thumbnailRelativePath
        )
    }

    /// Arcsec preferred over pixels -- the exact fallback order
    /// `NightWorkspaceView.fwhmText`/`qualityStatItems` already apply to the
    /// same `SessionQualitySummary` fields.
    static func fwhmText(_ quality: SessionQualitySummary?) -> String {
        if let arcsec = quality?.medianFWHMArcsec { return AstroFormat.fwhmArcsec(arcsec) }
        if let px = quality?.medianFWHMPixels { return AstroFormat.fwhmPixels(px) }
        return unmeasuredText
    }

    static func backgroundText(_ quality: SessionQualitySummary?) -> String {
        if let background = quality?.backgroundEPerSecPerArcsec2 {
            return AstroFormat.backgroundEPerSecArcsec2(background)
        }
        return unmeasuredText
    }

    /// A stable, filesystem-safe `NSSavePanel` suggested filename --
    /// `"<target>_<date>_session-card.png"` with anything that is not a
    /// letter/digit/`-`/`_` in `targetName` collapsed to `_`, since a
    /// project display name can carry spaces or punctuation (e.g. "IC 4604
    /// Rho Ophiuchi") that would otherwise round-trip oddly through a save
    /// panel's filename field.
    public static func suggestedFilename(targetName: String, dateText: String) -> String {
        let safeTarget = targetName.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return "\(String(safeTarget))_\(dateText)_session-card.png"
    }
}
