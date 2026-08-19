import AstroApplication
import AstroCore
import Foundation

/// Loads `NightRibbonQuery`'s assembly for `NightWorkspaceView`'s Overview
/// tab -- same `@MainActor`/`@Observable`/generation-guard shape
/// `NightReportStore` already established for this workspace's other
/// async-loaded data. `load` takes the report's own already-loaded
/// `SessionTimeline` rather than re-querying it, so a night's capture/gap
/// bands can never drift from the report's own "Idővonal" numbers -- see
/// `NightRibbonQuery`'s own doc comment.
@MainActor
@Observable
public final class NightRibbonStore {
    public typealias QueryFactory = @Sendable (URL) throws -> NightRibbonQuery

    public private(set) var result: NightRibbonModel?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let queryFactory: QueryFactory
    private var loadGeneration = 0

    public init(queryFactory: @escaping QueryFactory = { try NightRibbonQuery.production(rootURL: $0) }) {
        self.queryFactory = queryFactory
    }

    /// `target`/`rootURL`/`timeline` are all optional: a night with no
    /// associated project, no open library, or a report that hasn't loaded
    /// yet has nothing to build a ribbon from -- clears any previous result
    /// rather than surfacing a stale one.
    public func load(rootURL: URL?, target: String?, date: String, timeline: SessionTimeline?) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let rootURL, let target, let timeline else {
            result = nil
            errorMessage = nil
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let query = try queryFactory(rootURL)
            // Sky-geometry resolution touches the DB (site + target
            // coordinates) -- keep it off the main thread, same as
            // `NightReportStore.load` already does for `NightReportQuery.run`.
            let loaded = try await Task.detached(priority: .userInitiated) {
                try query.run(target: target, date: date, timeline: timeline)
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
