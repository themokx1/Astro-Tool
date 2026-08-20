import AstroApplication
import Foundation

/// Loads `NightReportQuery`'s assembly for `NightWorkspaceView`'s Overview
/// tab (W5-1). Follows the same `@MainActor`/`@Observable`/generation-guard
/// shape `ResultsStore` already established for this codebase's other
/// async-loaded workspace data -- a load that is no longer the newest
/// writes nothing, so a fast night switch can't have a slower query land on
/// top of a newer one.
@MainActor
@Observable
public final class NightReportStore {
    public typealias QueryFactory = @Sendable (URL) throws -> NightReportQuery

    public private(set) var result: NightReportQuery.Result?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let queryFactory: QueryFactory
    private var loadGeneration = 0

    public init(queryFactory: @escaping QueryFactory = { try NightReportQuery.production(rootURL: $0) }) {
        self.queryFactory = queryFactory
    }

    /// `target`/`rootURL` are both optional: a night with no associated
    /// project, or no library open at all, has nothing to query -- clears
    /// any previous result rather than surfacing a stale one.
    public func load(rootURL: URL?, target: String?, date: String) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let rootURL, let target else {
            result = nil
            errorMessage = nil
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let query = try queryFactory(rootURL)
            // `NightReportQuery.run` is a synchronous, DB-reading call --
            // run it off the main actor exactly the way `ResultsStore.load`
            // already keeps `stackResults`' own scan off the main thread.
            let loaded = try await Task.detached(priority: .userInitiated) {
                try query.run(target: target, date: date)
            }.value
            guard generation == loadGeneration else { return }
            result = loaded
            isLoading = false
        } catch {
            guard generation == loadGeneration else { return }
            result = nil
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
