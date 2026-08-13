import AstroCore
import CryptoKit
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

public enum CleanupPreviewError: Error, Equatable, Sendable {
    /// `plan(selecting:confirmationToken:)` needs the library root to read
    /// file bytes (for fingerprints) and to build absolute source/
    /// destination URLs -- thrown instead of silently building an empty
    /// plan when the query was constructed without one (`snapshot()` alone
    /// never needs it, since it only reads the index database).
    case libraryRootUnavailable
    /// None of `categories` matched a group in the current cleanup summary,
    /// or every matching group's findings were file-read failures -- rather
    /// than register and apply an empty `LibraryMutationPlan`.
    case noCandidatesSelected
}

/// Read-only cleanup-candidate preview, plus (mutation-gated) plan-building
/// for the quarantine-apply flow. `snapshot()` never touches the
/// filesystem, only the read-only index database; `plan(selecting:
/// confirmationToken:)` reads the *current* bytes of every selected
/// candidate file (to fingerprint it) but never writes anything -- the
/// actual move only ever happens through `QuarantineApplyCommand` /
/// `LibraryMutationAuthorizer`.
public struct CleanupPreviewQuery: Sendable {
    private let indexDatabase: URL
    private let rootURL: URL?
    private let identity: LibraryIdentity?
    private let accessMode: LibraryAccessMode

    private init(
        indexDatabase: URL,
        rootURL: URL?,
        identity: LibraryIdentity?,
        accessMode: LibraryAccessMode
    ) {
        self.indexDatabase = indexDatabase
        self.rootURL = rootURL
        self.identity = identity
        self.accessMode = accessMode
    }

    init(
        indexDatabaseForTesting: URL,
        rootURL: URL? = nil,
        accessMode: LibraryAccessMode = .readOnly
    ) {
        self.init(
            indexDatabase: indexDatabaseForTesting,
            rootURL: rootURL?.standardizedFileURL,
            identity: rootURL.map(LibraryIdentity.init(rootURL:)),
            accessMode: accessMode
        )
    }

    public static func production(rootURL: URL, accessMode: LibraryAccessMode = .readOnly) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return Self(
            indexDatabase: storage.indexDatabase,
            rootURL: rootURL.standardizedFileURL,
            identity: identity,
            accessMode: accessMode
        )
    }

    public func snapshot() async throws -> CleanupPreviewSnapshot {
        let summary = try CleanupReport.build(
            readOnlyDatabasePath: indexDatabase.standardizedFileURL.path,
            config: AstroConfig()
        )
        let canApply = accessMode == .mutationEnabled
        return .init(
            groups: summary.groups.map {
                .init(category: $0.category, fileCount: $0.fileCount, totalBytes: $0.totalBytes,
                      paths: $0.paths, truncatedCount: $0.truncatedCount, action: .quarantine)
            },
            totalBytes: summary.grandTotalBytes, isReadOnly: !canApply, canApply: canApply
        )
    }

    /// Builds a `LibraryMutationPlan` moving every file in the selected
    /// cleanup categories into `.astro_tool/cleanup_quarantine/<stamp>/` --
    /// the exact destination scheme `CleanupReport.quarantineFindings`
    /// already defines for the CLI's `cleanup --suggest`, reused here
    /// rather than re-derived so the two never drift. Available regardless
    /// of `accessMode` (building a preview plan never writes anything);
    /// `QuarantineApplyCommand.apply` is what actually gates on write
    /// access.
    public func plan(
        selecting categories: Set<String>,
        confirmationToken: String,
        timestamp: Date = Date()
    ) throws -> LibraryMutationPlan {
        guard let rootURL, let identity else { throw CleanupPreviewError.libraryRootUnavailable }
        let summary = try CleanupReport.build(
            readOnlyDatabasePath: indexDatabase.standardizedFileURL.path,
            config: AstroConfig(),
            maxPathsPerGroup: .max
        )
        let selectedGroups = summary.groups.filter { categories.contains($0.category) }
        guard !selectedGroups.isEmpty else { throw CleanupPreviewError.noCandidatesSelected }
        let selectedSummary = CleanupSummary(
            groups: selectedGroups,
            grandTotalBytes: selectedGroups.reduce(Int64(0)) { $0 + $1.totalBytes }
        )
        let findings = CleanupReport.quarantineFindings(for: selectedSummary, timestamp: timestamp)

        var entries: [LibraryMutationPlan.Entry] = []
        var totalBytes: Int64 = 0
        for finding in findings {
            guard case .move(let from, let to) = finding.suggestion else { continue }
            let sourceURL = rootURL.appendingPathComponent(from)
            let destinationURL = rootURL.appendingPathComponent(to)
            let data = try Data(contentsOf: sourceURL)
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            entries.append(.init(source: sourceURL, destination: destinationURL, fingerprint: fingerprint))
            totalBytes += Int64(data.count)
        }
        guard !entries.isEmpty else { throw CleanupPreviewError.noCandidatesSelected }

        return LibraryMutationPlan(
            libraryID: identity,
            revision: QuarantineApplyCommand.revision,
            entries: entries,
            totalBytes: totalBytes,
            confirmationToken: confirmationToken
        )
    }
}
