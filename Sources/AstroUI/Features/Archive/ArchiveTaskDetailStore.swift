import AstroApplication
import Foundation
import Observation

/// Loads the full finding set behind one `ArchiveTaskKind` for
/// `ArchiveTaskDetailView` -- the destination `ArchiveTaskAction.showFindings`
/// pushes to. Follows `ArchiveStore`'s own shape exactly (its doc comment
/// spells out why): a side-effect-free `init`, no query in a computed
/// getter, and a generation guard on the async load so a superseded slow
/// load (e.g. the user backs out and reopens a different kind's list before
/// the first load finishes) can never overwrite a newer result or clear its
/// `isLoading`. `totalBytes` is summed once here, at load time, rather than
/// as a computed property the view would otherwise re-reduce over
/// potentially thousands of rows on every render.
@MainActor
@Observable
public final class ArchiveTaskDetailStore {
    public typealias FindingsFactory = @Sendable (URL, ArchiveTaskKind) async throws -> [ArchiveFinding]

    public private(set) var findings: [ArchiveFinding] = []
    public private(set) var totalBytes: Int64 = 0
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let factory: FindingsFactory
    private var generation = 0

    public init(
        factory: @escaping FindingsFactory = { rootURL, kind in
            try await ArchiveTaskQuery.production(rootURL: rootURL).findings(for: kind)
        }
    ) {
        self.factory = factory
    }

    public func load(rootURL: URL, kind: ArchiveTaskKind) async {
        generation += 1
        let token = generation
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await factory(rootURL, kind)
            guard token == generation else { return }
            findings = loaded
            totalBytes = loaded.reduce(0) { $0 + $1.bytes }
        } catch {
            guard token == generation else { return }
            findings = []
            totalBytes = 0
            errorMessage = error.localizedDescription
        }
        if token == generation { isLoading = false }
    }
}
