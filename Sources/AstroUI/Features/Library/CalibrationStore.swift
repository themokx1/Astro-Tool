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

    public private(set) var coverage: [CalibNeed] = []
    public private(set) var masters: [CalibrationMasterInfo] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var accessMode: LibraryAccessMode = .readOnly

    public private(set) var linkPlan: CalibLinkPlan?
    public private(set) var isPlanning = false
    public private(set) var planErrorMessage: String?
    public private(set) var lastReceipt: CalibrationLinkReceipt?

    private let queryFactory: QueryFactory
    private let commandFactory: CommandFactory
    private var rootURL: URL?

    public init(
        queryFactory: @escaping QueryFactory = { rootURL in try CalibrationQuery.production(rootURL: rootURL) },
        commandFactory: @escaping CommandFactory = { rootURL, accessMode in
            try CalibrationLinkCommand.production(rootURL: rootURL, accessMode: accessMode)
        }
    ) {
        self.queryFactory = queryFactory
        self.commandFactory = commandFactory
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
        } catch {
            errorMessage = error.localizedDescription
        }
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
            }
        } catch LibraryMutationError.readOnly {
            planErrorMessage = "Requires write access. Enable write operations in Settings to link calibration files."
        } catch {
            planErrorMessage = error.localizedDescription
        }
    }
}
