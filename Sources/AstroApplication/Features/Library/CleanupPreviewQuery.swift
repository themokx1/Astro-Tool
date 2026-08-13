import AstroCore
import Foundation

public enum CleanupPreviewAction: String, Sendable { case quarantine }

public struct CleanupPreviewGroup: Equatable, Sendable, Identifiable {
    public var id: String { category }
    public let category: String
    public let fileCount: Int
    public let totalBytes: Int64
    public let paths: [String]
    public let truncatedCount: Int
    public let action: CleanupPreviewAction
}

public struct CleanupPreviewSnapshot: Equatable, Sendable {
    public let groups: [CleanupPreviewGroup]
    public let totalBytes: Int64
    public let isReadOnly: Bool
    public let canApply: Bool
}

public struct CleanupPreviewQuery: Sendable {
    private let indexDatabase: URL
    private init(indexDatabase: URL) { self.indexDatabase = indexDatabase }
    init(indexDatabaseForTesting: URL) { self.indexDatabase = indexDatabaseForTesting }

    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return Self(indexDatabase: storage.indexDatabase)
    }

    public func snapshot() async throws -> CleanupPreviewSnapshot {
        let summary = try CleanupReport.build(
            readOnlyDatabasePath: indexDatabase.standardizedFileURL.path,
            config: AstroConfig()
        )
        return .init(
            groups: summary.groups.map {
                .init(category: $0.category, fileCount: $0.fileCount, totalBytes: $0.totalBytes,
                      paths: $0.paths, truncatedCount: $0.truncatedCount, action: .quarantine)
            },
            totalBytes: summary.grandTotalBytes, isReadOnly: true, canApply: false
        )
    }
}
