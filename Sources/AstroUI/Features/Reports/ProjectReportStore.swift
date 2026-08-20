import AstroApplication
import Foundation

/// Loads `ProjectReportQuery`'s assembly for `ProjectWorkspaceView`'s
/// Áttekintés (Overview) tab (W5-1). Same `@MainActor`/`@Observable`/
/// generation-guard shape as `NightReportStore`/`ResultsStore` -- see
/// either's own doc comment for why.
@MainActor
@Observable
public final class ProjectReportStore {
    public typealias QueryFactory = @Sendable (URL) throws -> ProjectReportQuery

    public private(set) var result: ProjectReportQuery.Result?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let queryFactory: QueryFactory
    private var loadGeneration = 0

    public init(queryFactory: @escaping QueryFactory = { try ProjectReportQuery.production(rootURL: $0) }) {
        self.queryFactory = queryFactory
    }

    public func load(rootURL: URL?, target: String) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let rootURL else {
            result = nil
            errorMessage = nil
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let query = try queryFactory(rootURL)
            let loaded = try await Task.detached(priority: .userInitiated) {
                try query.run(target: target)
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
