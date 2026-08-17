import AstroCore
import Foundation

/// The result of an acquisition export: rendered `content` ready to hand to
/// an `NSSavePanel` destination, a `suggestedFilename` for that panel's name
/// field, and (astrobin only) `unmappedFilters` -- the filters this export
/// actually used that have no `config.astrobin.filterIds` entry yet, same
/// warning V1's `AppState.exportAcquisition` surfaces as a post-export toast
/// (`AcquisitionExport.unmappedAstrobinFilters`). Always `[]` for `csv`/`md`,
/// which don't carry an AstroBin filter ID column at all.
public struct AcquisitionExportResult: Sendable, Equatable {
    public let content: String
    public let suggestedFilename: String
    public let unmappedFilters: [String]
}

/// One rendered file-shaped export: content plus a suggested destination
/// filename for the `NSSavePanel` that will actually write it.
public struct RenderedExport: Sendable, Equatable {
    public let content: String
    public let suggestedFilename: String
}

/// V2's single entry point for every export V1 exposes through `AppState`'s
/// `exportAcquisition`/`exportTargetReport`/`exportNightReport`/
/// `exportStackList`/`copyPlanToClipboard`/`exportPlanToCSV`/
/// `copyCalibShoppingListToClipboard` -- every method here is a thin
/// projection over an existing `AstroCore` engine (`AcquisitionExport`,
/// `TargetReport`, `NightReport`, `StackList`, `PlanExport`,
/// `CalibShoppingList`); nothing here re-derives a number or re-implements a
/// file format any of those doesn't already own.
///
/// Deliberately produces content only -- never touches the filesystem or the
/// pasteboard itself. V1 wrote straight into `.astro_tool/exports`/`reports`/
/// `stacklists` via `WriteGuard`; V2 instead hands the rendered `String` to
/// whatever `NSSavePanel`-chosen destination the user picks (`ExportMenu`/
/// `ExportFileWriter` in `AstroUI`), or straight to `NSPasteboard` for the
/// clipboard-only exports -- matching this worktree's "file writes go ONLY
/// to user-chosen `NSSavePanel` destinations" rule.
public struct ExportService: Sendable {
    private let db: Database
    private let config: AstroConfig
    private let rootURL: URL

    public init(db: Database, config: AstroConfig, rootURL: URL) {
        self.db = db
        self.config = config
        self.rootURL = rootURL
    }

    /// Resolves `target` against the library's actually-scanned folders
    /// before handing it to any `AstroCore` export engine.
    ///
    /// One-letter-drift fix (2026-08-17): every method below used to pass
    /// its `target` straight through to `AcquisitionExport`/`TargetReport`/
    /// `NightReport`/`StackList`, and every one of those engines matches
    /// `db.allFiles`/`SessionStatsQueries` rows by exact string equality.
    /// V2's own UI hands this `target` in as `ProjectsQuery.
    /// canonicalFolderName(for:)` -- the catalog's own idea of the folder
    /// name -- which is NOT guaranteed to be the spelling the scanner
    /// actually recorded (measured on the owner's real library: NGC 7000's
    /// canonical `NGC_7000_North_America_Nebula` vs. the 62 real files under
    /// `NGC_7000_North_American_Nebula`). An exact match silently exported
    /// nothing for that project. This asks the identical resolver the
    /// Results page already fixed this same defect with --
    /// `TargetCatalog.existingFolder(for:among:)` via `ResultsQuery.
    /// libraryFolder(matching:among:)`, never a new comparison of its own --
    /// against the distinct target folders the scanner actually recorded,
    /// same source `ResultsQuery.production`'s own `libraryTargets` reads.
    /// Falls back to `target` unchanged when nothing resolves, so an
    /// unscanned/free-text target keeps failing exactly as loudly as before
    /// (see `nightReportThrowsForUnknownSession`).
    private func resolvedTarget(_ target: String) throws -> String {
        let knownFolders = Array(Set(try db.allFiles(includeMissing: false).compactMap(\.target)))
        return ResultsQuery.libraryFolder(matching: target, among: knownFolders) ?? target
    }

    /// Opens the production index DB/config for `rootURL`, same "read the
    /// already-scanned library, never re-scan" shape every other V2
    /// `.production(rootURL:)` factory (`CalibrationQuery`, `FrameQualityQuery`,
    /// ...) already follows.
    public static func production(rootURL: URL) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        return Self(db: database, config: config, rootURL: root)
    }

    // MARK: - Acquisition export (astrobin / csv / md)

    /// Renders `target`'s acquisition report in `format`
    /// (`AcquisitionExport.render`), plus (astrobin only) the unmapped-filter
    /// warning (`AcquisitionExport.unmappedAstrobinFilters`) -- exactly the
    /// pair V1's `exportAcquisition` computes before writing/toasting.
    public func acquisitionExport(target: String, format: ExportFormat) throws -> AcquisitionExportResult {
        let target = try resolvedTarget(target)
        let content = try AcquisitionExport.render(target: target, format: format, db: db, config: config)
        let unmapped = format == .astrobin
            ? try AcquisitionExport.unmappedAstrobinFilters(target: target, db: db, config: config)
            : []
        let ext = format == .md ? "md" : "csv"
        return AcquisitionExportResult(
            content: content,
            suggestedFilename: "\(Sanitizer.sanitize(target))-\(format.rawValue)-acquisition.\(ext)",
            unmappedFilters: unmapped
        )
    }

    // MARK: - Target report (R8-2)

    /// The full "everything about one target" HTML report (`TargetReport.render`).
    public func targetReport(target: String) throws -> RenderedExport {
        let target = try resolvedTarget(target)
        let html = try TargetReport.render(target: target, db: db, config: config)
        return RenderedExport(content: html, suggestedFilename: "target-\(Sanitizer.sanitize(target)).html")
    }

    // MARK: - Night report (R7-B5)

    /// One session's HTML night-report card (`NightReport.render`).
    public func nightReport(target: String, date: String) throws -> RenderedExport {
        let target = try resolvedTarget(target)
        let html = try NightReport.render(target: target, date: date, db: db, config: config)
        return RenderedExport(content: html, suggestedFilename: "\(Sanitizer.sanitize(target))-\(date).html")
    }

    // MARK: - Stack list

    /// This session's best-frame selection (`StackList.select`), rendered as
    /// its manifest CSV (`StackList.renderManifest`) -- the same
    /// human-readable "what got selected and why" record a physical
    /// `StackList.export` would write to `manifest.csv`, without hardlinking
    /// anything onto disk.
    public func stackList(target: String, date: String, keepFraction: Double = 0.8) throws -> RenderedExport {
        let target = try resolvedTarget(target)
        let selection = try StackList.select(
            target: target, date: date, keepFraction: keepFraction, db: db, config: config
        )
        let content = StackList.renderManifest(selection, libraryRoot: rootURL)
        return RenderedExport(
            content: content,
            suggestedFilename: "\(StackList.slug(target: target, date: date))-manifest.csv"
        )
    }

    // MARK: - Tonight's plan (R11-T6/F18a)

    /// Tonight's plan as CSV (`PlanExport.renderCSV`) -- pure, needs no
    /// `Database`/filesystem access beyond what the caller's already-computed
    /// `plans` provide (same as `PlanExport` itself).
    public func planCSV(plans: [TargetPlan], night: String = "") -> RenderedExport {
        let stamp = night.isEmpty ? "tonight" : night
        return RenderedExport(content: PlanExport.renderCSV(plans, night: night), suggestedFilename: "plan-\(stamp).csv")
    }

    /// Tonight's plan as tab-separated clipboard text (`PlanExport.renderClipboardText`).
    public func planClipboardText(plans: [TargetPlan]) -> String {
        PlanExport.renderClipboardText(plans)
    }

    // MARK: - Calibration shopping list (R11-T6/F18b)

    /// Tonight's calibration shopping list as Markdown (`CalibShoppingList.markdown`).
    public func calibShoppingListMarkdown(items: [CalibShoppingList.Item]) -> String {
        CalibShoppingList.markdown(items)
    }
}
