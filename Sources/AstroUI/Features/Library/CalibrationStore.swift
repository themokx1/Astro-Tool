import AstroApplication
import AstroCore
import Foundation
import Observation

/// Backs `CalibrationView`: loads per-session dark coverage and the
/// master-dark inventory (`CalibrationQuery`), and drives the link-preview
/// -> apply flow (`CalibrationLinkCommand`) gated on `LibraryAccessMode`.
/// Follows `LibraryHealthStore`'s query-factory injection pattern so tests
/// can supply a fixture-backed `CalibrationQuery`/`CalibrationLinkCommand`
/// without touching the filesystem-resolving `production` constructors.
@MainActor
@Observable
public final class CalibrationStore {
    public typealias QueryFactory = @Sendable (URL) throws -> CalibrationQuery
    public typealias CommandFactory = @Sendable (URL, LibraryAccessMode) throws -> CalibrationLinkCommand
    /// Section 5.2 (Kalibrációs automata): same injection shape as
    /// `CommandFactory` above, for `CalibrationMasterBuildCommand` instead.
    public typealias BuildCommandFactory = @Sendable (URL, LibraryAccessMode) throws -> CalibrationMasterBuildCommand

    public private(set) var coverage: [CalibNeed] = []
    public private(set) var masters: [CalibrationMasterInfo] = []
    /// V2 UI/UX audit (2026-08-14) systemic pattern S7: `masters` is this
    /// store's own cached collection (unlike `coverage`, which
    /// `CalibrationView` wraps and sorts locally -- see that view's own doc
    /// comment for why), so the sort lives here, applied whenever `masters`
    /// is (re)loaded. Default is path ascending -- simple and deterministic.
    public private(set) var mastersSortOrder: [KeyPathComparator<CalibrationMasterInfo>] = [
        KeyPathComparator(\CalibrationMasterInfo.path, order: .forward)
    ]
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var accessMode: LibraryAccessMode = .readOnly

    public private(set) var linkPlan: CalibLinkPlan?
    public private(set) var isPlanning = false
    public private(set) var planErrorMessage: String?
    public private(set) var lastReceipt: CalibrationLinkReceipt?
    /// Fired after `applyPlan()` succeeds -- lets `V2RootView` keep the
    /// sidebar's Library badge fresh without this store needing to know
    /// anything about `SidebarBadgeStore` itself (wave 3 follow-up fix: the
    /// badge previously never refreshed after linking a calibration master).
    public var onLibraryFindingsChanged: (() -> Void)?

    // MARK: - Section 5.2 (Kalibrációs automata): master-build preview/apply

    public private(set) var buildPreview: CalibrationMasterBuildPreview?
    public private(set) var isPreviewingBuild = false
    public private(set) var buildErrorMessage: String?
    public private(set) var isBuilding = false
    public private(set) var lastBuildReceipt: CalibrationMasterBuildReceipt?

    private let queryFactory: QueryFactory
    private let commandFactory: CommandFactory
    private let buildCommandFactory: BuildCommandFactory
    private var rootURL: URL?
    /// The `CalibNeed` `prepareBuildPreview(need:)` was last called with --
    /// kept so `setAutoMasterBuildEnabled(_:)` can refresh `buildPreview` in
    /// place after flipping the config gate, without the caller having to
    /// pass the same `need` back in a second time.
    private var previewedNeed: CalibNeed?

    public init(
        queryFactory: @escaping QueryFactory = { rootURL in try CalibrationQuery.production(rootURL: rootURL) },
        commandFactory: @escaping CommandFactory = { rootURL, accessMode in
            try CalibrationLinkCommand.production(rootURL: rootURL, accessMode: accessMode)
        },
        buildCommandFactory: @escaping BuildCommandFactory = { rootURL, accessMode in
            try CalibrationMasterBuildCommand.production(rootURL: rootURL, accessMode: accessMode)
        }
    ) {
        self.queryFactory = queryFactory
        self.commandFactory = commandFactory
        self.buildCommandFactory = buildCommandFactory
    }

    public func load(rootURL: URL, accessMode: LibraryAccessMode = .readOnly) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        self.rootURL = rootURL.standardizedFileURL
        self.accessMode = accessMode
        do {
            let query = try queryFactory(rootURL)
            coverage = try query.coverage()
            masters = try query.masterInventory()
            sortMasters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setMastersSortOrder(_ newValue: [KeyPathComparator<CalibrationMasterInfo>]) {
        guard newValue != mastersSortOrder else { return }
        mastersSortOrder = newValue
        sortMasters()
    }

    private func sortMasters() {
        guard !mastersSortOrder.isEmpty else { return }
        masters.sort(using: mastersSortOrder)
    }

    /// Builds a link preview for `target`/`date` -- always available
    /// regardless of `accessMode`; populates `linkPlan` for the preview
    /// sheet. Nothing is written by this call.
    public func preparePlan(target: String, date: String) async {
        guard let rootURL else { return }
        isPlanning = true
        planErrorMessage = nil
        defer { isPlanning = false }
        do {
            let command = try commandFactory(rootURL, accessMode)
            linkPlan = try command.plan(target: target, date: date)
            lastReceipt = nil
        } catch {
            planErrorMessage = error.localizedDescription
        }
    }

    /// Dismisses the current preview/receipt state, e.g. when the preview
    /// sheet is closed.
    public func clearPlan() {
        linkPlan = nil
        planErrorMessage = nil
        lastReceipt = nil
    }

    /// Applies the currently previewed `linkPlan`. In `.readOnly` mode this
    /// sets `planErrorMessage` to an explanatory message and links nothing
    /// -- the UI is expected to disable the apply control in that mode
    /// already, this is the belt-and-suspenders backstop. On success,
    /// refreshes `masters`/`coverage` so a newly-linked master is reflected
    /// immediately.
    public func applyPlan() async {
        guard let rootURL, let linkPlan else { return }
        do {
            let command = try commandFactory(rootURL, accessMode)
            lastReceipt = try command.apply(linkPlan)
            planErrorMessage = nil
            if let query = try? queryFactory(rootURL) {
                coverage = (try? query.coverage()) ?? coverage
                masters = (try? query.masterInventory()) ?? masters
                sortMasters()
            }
            onLibraryFindingsChanged?()
        } catch LibraryMutationError.readOnly {
            planErrorMessage = "Requires write access. Enable write operations in Settings to link calibration files."
        } catch {
            planErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Section 5.2 (Kalibrációs automata): master-build preview/apply

    /// Builds the read-only build preview for one dark `CalibNeed` -- always
    /// available regardless of `accessMode`, same "plan first" shape as
    /// `preparePlan(target:date:)` above. Nothing is written by this call.
    public func prepareBuildPreview(need: CalibNeed) async {
        guard let rootURL else { return }
        isPreviewingBuild = true
        buildErrorMessage = nil
        defer { isPreviewingBuild = false }
        previewedNeed = need
        do {
            let command = try buildCommandFactory(rootURL, accessMode)
            buildPreview = try command.preview(need: need)
            lastBuildReceipt = nil
        } catch {
            buildErrorMessage = error.localizedDescription
        }
    }

    /// Dismisses the current build preview/receipt state, e.g. when the
    /// build sheet is closed.
    public func clearBuildPreview() {
        buildPreview = nil
        buildErrorMessage = nil
        lastBuildReceipt = nil
        previewedNeed = nil
    }

    /// Flips `AstroConfig.CalibRule.autoMasterBuildEnabled` and persists it
    /// via `WriteGuard.writeToolFile` (the same mechanism
    /// `AstroConfig.save(using:)` always uses) -- the explicit, separate
    /// opt-in that field's own doc comment describes, alongside
    /// `LibraryAccessMode.mutationEnabled`, before `buildMaster` will ever
    /// run Siril. Refreshes `buildPreview` in place afterward (if a preview
    /// is currently open) so the sheet's own "enable it below" affordance
    /// reflects the new state immediately, without the caller re-triggering
    /// `prepareBuildPreview` itself.
    public func setAutoMasterBuildEnabled(_ enabled: Bool) async {
        guard let rootURL else { return }
        do {
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            config.calib.autoMasterBuildEnabled = enabled
            let writeGuard = WriteGuard(root: rootURL)
            try config.save(using: writeGuard)
        } catch {
            buildErrorMessage = error.localizedDescription
            return
        }
        if let previewedNeed {
            await prepareBuildPreview(need: previewedNeed)
        }
    }

    /// Runs the Siril-backed dark-master build for `need` through
    /// `OperationHost`, so it shows up in the toolbar with progress/cancel
    /// UI and gets `OperationHost`'s own success/failure toast -- same shape
    /// as `LibraryHealthStore.runAudit`. `cancellation: .unavailable`
    /// because the underlying `SirilMasterBuilder`/`Process` call has no
    /// cooperative cancellation of its own (its 300s timeout is the only
    /// bound, matching `SirilCLI.metrics`'s own single-frame call).
    ///
    /// On success, refreshes `masters`/`coverage` so the gap-list row this
    /// combo used to be on disappears (or its stale flag clears) the moment
    /// `CalibAnalyzer.coverage()` finds the new master -- there is no
    /// separate "build succeeded" flag; the gap list is the only source of
    /// truth (this feature's own spec).
    public func buildMaster(need: CalibNeed, operationHost: OperationHost) async {
        guard let rootURL else { return }
        let tempLabel: String = need.tempC.map { "\($0)" } ?? "notemp"
        let comboKey = "\(need.exposureSeconds)s/\(tempLabel)"
        let kind = OperationKind.buildMaster(combo: comboKey)
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else {
            operationHost.notify(.info, message: OperationHost.localized("A master build is already running for this combo."))
            return
        }

        buildErrorMessage = nil
        isBuilding = true
        do {
            let command = try buildCommandFactory(rootURL, accessMode)
            let title = "\(OperationHost.localized("Building master dark")) \(comboKey)"
            let id = await operationHost.run(kind: kind, title: title, cancellation: .unavailable) { [weak self] in
                do {
                    let receipt = try command.buildDarkMaster(need: need)
                    await self?.recordBuildSuccess(receipt: receipt, rootURL: rootURL)
                } catch {
                    await self?.recordBuildFailure(error)
                    throw error
                }
            }
            _ = await operationHost.outcome(of: id)
        } catch {
            buildErrorMessage = Self.describeBuildError(error)
        }
        isBuilding = false
    }

    private func recordBuildSuccess(receipt: CalibrationMasterBuildReceipt, rootURL: URL) async {
        lastBuildReceipt = receipt
        buildErrorMessage = nil
        if let query = try? queryFactory(rootURL) {
            coverage = (try? query.coverage()) ?? coverage
            masters = (try? query.masterInventory()) ?? masters
            sortMasters()
        }
        onLibraryFindingsChanged?()
    }

    private func recordBuildFailure(_ error: Error) async {
        buildErrorMessage = Self.describeBuildError(error)
    }

    /// Honest, specific copy per failure mode -- so the UI never falls back
    /// to a generic `error.localizedDescription` for a case this feature's
    /// own spec explicitly named a wording for (e.g. "csak 3 dark van,
    /// minimum 10 kell").
    private static func describeBuildError(_ error: Error) -> String {
        switch error {
        case LibraryMutationError.readOnly:
            return "Requires write access. Enable write operations in Settings to build calibration masters."
        case CalibrationMasterBuildError.autoBuildDisabled:
            return "Automatic master build is turned off. Enable it below to build this master."
        case let CalibrationMasterBuildError.insufficientFrames(have, minimum):
            return "Not enough dark frames to build a master automatically (\(have) found, \(minimum) needed) — build it manually in Siril."
        case let CalibrationMasterBuildError.heterogeneousSources(reasons):
            return "Source dark frames are not consistent enough to build automatically (\(reasons.joined(separator: "; "))) — build it manually in Siril."
        case CalibrationMasterBuildError.noTemperature:
            return "This combo has no recorded temperature — build it manually in Siril."
        case let CalibrationMasterBuildError.sirilUnavailable(path):
            return "Siril was not found at \(path). Set the Siril path in Settings, or build this master manually."
        case CalibrationMasterBuildError.buildFailed:
            return "Automatic master build failed — open Siril manually. It never wrote a partial master file."
        default:
            return error.localizedDescription
        }
    }
}
