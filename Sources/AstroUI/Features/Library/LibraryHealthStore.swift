import AstroApplication
import Foundation
import Observation

@MainActor
@Observable
public final class LibraryHealthStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore
    public typealias QueryFactory = @Sendable (URL, MetadataStore) throws -> LibraryHealthQuery

    public private(set) var snapshot: LibraryHealthSnapshot?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var showAcknowledged = false

    private let metadataFactory: MetadataFactory
    private let queryFactory: QueryFactory
    private var metadata: MetadataStore?
    private var rootURL: URL?

    public init(
        metadataFactory: @escaping MetadataFactory = LibraryHealthStore.productionMetadata,
        queryFactory: @escaping QueryFactory = { rootURL, metadata in
            try LibraryHealthQuery.production(rootURL: rootURL, metadata: metadata)
        }
    ) {
        self.metadataFactory = metadataFactory
        self.queryFactory = queryFactory
    }

    public func load(rootURL: URL) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let metadata = try metadataFactory(rootURL.standardizedFileURL)
            self.metadata = metadata
            self.rootURL = rootURL.standardizedFileURL
            snapshot = try await queryFactory(rootURL, metadata).snapshot(includeAcknowledged: showAcknowledged)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggles whether already-acknowledged findings stay visible (dimmed by
    /// the caller) instead of being hidden, then reloads to apply it.
    public func setShowAcknowledged(_ value: Bool) async {
        showAcknowledged = value
        await refresh()
    }

    /// Marks one finding group as acknowledged and refreshes the rows.
    public func acknowledge(_ item: LibraryHealthItem, note: String? = nil) async {
        guard let metadata else { return }
        do {
            try await metadata.acknowledgeFindingGroup(
                category: item.ackCategory, groupKey: item.ackGroupKey, note: note
            )
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reverses `acknowledge` and refreshes the rows.
    public func revokeAcknowledgement(_ item: LibraryHealthItem) async {
        guard let metadata else { return }
        do {
            try await metadata.revokeAcknowledgement(
                ackKey: MetadataStore.ackKey(category: item.ackCategory, groupKey: item.ackGroupKey)
            )
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        guard let rootURL, let metadata else { return }
        do {
            snapshot = try await queryFactory(rootURL, metadata).snapshot(includeAcknowledged: showAcknowledged)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public static func productionMetadata(rootURL: URL) throws -> MetadataStore {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return try MetadataStore(storagePaths: storage)
    }
}
