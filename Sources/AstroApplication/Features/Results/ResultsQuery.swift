import AstroCore
import Foundation

/// Which of `StackDiscovery`'s own three file kinds a discovered file is --
/// a 1:1 relabeling of `StackFile.kind`'s raw string (AstroCore names them
/// in Hungarian: `"stack"`, `"master-jelölt"`, `"feldolgozott"`) into a case
/// the V2 UI can `switch` on and translate. The classification itself is
/// entirely the engine's (`StackDiscovery.kind(baseNameLower:area:ext:
/// sizeBytes:)`); nothing is re-decided here. An unrecognized string maps to
/// `.stack`, which is what the engine itself returns when no other rule
/// fires -- a new engine kind would show up as a plain stack rather than
/// crashing or vanishing.
public enum StackResultCategory: String, Equatable, Sendable, CaseIterable {
    case stack
    case calibrationMasterCandidate
    case processed

    init(engineKind: String) {
        switch engineKind {
        case "master-jelölt": self = .calibrationMasterCandidate
        case "feldolgozott": self = .processed
        default: self = .stack
        }
    }
}

/// Which top-level library area a discovered file physically sits in. This
/// is not a discovery rule -- `StackDiscovery` deliberately recognizes a
/// stack from its NAME, not its location -- it is display-only path
/// splitting, so the reader can see that a "result" is actually still
/// sitting loose in a session folder. Mirrors V1 `StacksSegment`'s own
/// `locationLabel`.
public enum StackResultLocation: String, Equatable, Sendable {
    case stacks
    case processed
    case sessions
    case libraryRoot

    init(relativePath: String) {
        switch relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) {
        case "stacks": self = .stacks
        case "processed": self = .processed
        case "sessions": self = .sessions
        default: self = .libraryRoot
        }
    }
}

/// One discovered stack/processed-output file, projected for the Results
/// page. Every value here is `StackFile`'s own, passed straight through --
/// nothing in this type re-derives what `StackDiscovery` already decided
/// (see `StackResultCategory`/`StackResultLocation` for the only two
/// relabelings, both display-only).
public struct StackResultFile: Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let fileName: String
    /// `StackDiscovery.variantKind(fileName:)`'s verdict -- original,
    /// edited, starless, starmask or export.
    public let variantKind: StackVariantKind
    public let category: StackResultCategory
    public let location: StackResultLocation
    public let sizeBytes: Int64
    public let sessionDate: String?
    public let modifiedAt: Date?
    /// `"6248×4176"` from the indexed FITS header, `nil` when unrecorded.
    public let dimensions: String?
    public let framesFromName: Int?
    public let subSecondsFromName: Double?
    public let totalSecondsFromName: Double?

    init(_ file: StackFile) {
        relativePath = file.path
        fileName = (file.path as NSString).lastPathComponent
        variantKind = file.variantKind
        category = StackResultCategory(engineKind: file.kind)
        location = StackResultLocation(relativePath: file.path)
        sizeBytes = file.sizeBytes
        sessionDate = file.sessionDate
        modifiedAt = file.modifiedISO.flatMap { ISO8601DateFormatter().date(from: $0) }
        dimensions = file.dimensions
        framesFromName = file.framesFromName
        subSecondsFromName = file.subSecondsFromName
        totalSecondsFromName = file.totalSecondsFromName
    }
}

/// One family of stack variants sharing an underlying capture --
/// `StackGroup` projected for display. `framesBest`/`subSecondsBest`/
/// `totalSecondsBest`/`exposureFromHeader` are the engine's own
/// name-parsed-then-FITS-header-fallback numbers, copied verbatim.
public struct StackResultGroup: Equatable, Sendable, Identifiable {
    public var id: String { stem }
    public let stem: String
    public let base: StackResultFile
    public let variants: [StackResultFile]
    public let framesBest: Int?
    public let subSecondsBest: Double?
    public let totalSecondsBest: Double?
    /// `true` when the exposure numbers came from `base`'s FITS header
    /// (`STACKCNT`/`LIVETIME`/`EXPTIME`) rather than its filename, so the UI
    /// can say so instead of implying the name carried them.
    public let exposureFromHeader: Bool

    public var fileCount: Int { 1 + variants.count }

    init(_ group: StackGroup) {
        stem = group.stem
        base = StackResultFile(group.base)
        variants = group.variants.map(StackResultFile.init)
        framesBest = group.framesBest
        subSecondsBest = group.subSecondsBest
        totalSecondsBest = group.totalSecondsBest
        exposureFromHeader = group.fromHeader
    }
}

/// Everything one project's Results page shows: the already-created stacks
/// and processed outputs `StackDiscovery` finds for that project's library
/// folder, collapsed into variant families.
///
/// There is deliberately no lineage here. Lineage would say WHICH FRAMES
/// went into a stack, and discovery cannot know that -- it recognizes a
/// finished output from its own filename. The `results`/`lineage_edges`
/// tables that could carry it have no writer anywhere in the product (see
/// `ResultsQuery.snapshot(projectID:)`'s own note), so a lineage panel here
/// would be a panel that can never fill.
public struct StackResultsSnapshot: Equatable, Sendable {
    /// The library folder the discovery actually ran against -- the folder
    /// name ON DISK, which is not always the project's own
    /// `ProjectsQuery.canonicalFolderName` (see `ResultsQuery.libraryFolder
    /// (matching:among:)`). Reported so the page can never name a folder the
    /// library does not have.
    public let target: String
    /// Best-integration-first, `StackDiscovery.stacks(target:)`'s own order.
    public let groups: [StackResultGroup]

    public init(target: String, groups: [StackResultGroup]) {
        self.target = target
        self.groups = groups
    }

    public var fileCount: Int { groups.reduce(0) { $0 + $1.fileCount } }
    /// The best-integration group, i.e. the first -- `nil` when empty.
    public var bestGroup: StackResultGroup? { groups.first }
}

public struct ResultLineageSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let parentResultID: UUID?
    public let kind: ResultKind
    public let role: ResultRole
    public let relativePath: String?
    public let createdAt: Date
    public let softwareName: String?
    public let softwareVersion: String?
    public let inputSeriesIDs: [UUID]
    public let sourceFrameIDs: [UUID]
    public let sourceResultIDs: [UUID]
    public let calibrationAssets: [String]

    /// `KeyPathComparator` needs a non-optional `Comparable` value -- joins
    /// name/version the same way `ResultsView.softwareLabel` displays them,
    /// falling back to empty (sorts first) when neither is recorded.
    public var softwareSortKey: String {
        [softwareName, softwareVersion].compactMap { $0 }.joined(separator: " ")
    }
}

public struct ResultsSnapshot: Equatable, Sendable {
    public let projectID: UUID
    public let results: [ResultLineageSnapshot]
    public let publishableResultID: UUID?
}

/// A library-wide (cross-project) searchable projection of one result,
/// naming the project it belongs to so callers -- notably global search --
/// don't need a project already selected to find or route to it.
public struct ResultSearchEntry: Equatable, Sendable, Identifiable {
    public var id: UUID { resultID }
    public let resultID: UUID
    public let projectID: UUID
    public let projectName: String
    public let kind: ResultKind
    public let role: ResultRole
    public let relativePath: String?
    public let softwareName: String?
    public let softwareVersion: String?
    public let createdAt: Date

    public init(
        resultID: UUID,
        projectID: UUID,
        projectName: String,
        kind: ResultKind,
        role: ResultRole,
        relativePath: String?,
        softwareName: String?,
        softwareVersion: String?,
        createdAt: Date
    ) {
        self.resultID = resultID
        self.projectID = projectID
        self.projectName = projectName
        self.kind = kind
        self.role = role
        self.relativePath = relativePath
        self.softwareName = softwareName
        self.softwareVersion = softwareVersion
        self.createdAt = createdAt
    }
}

public struct ResultsQuery: Sendable {
    /// Resolves one library-folder name to `StackDiscovery`'s own grouped
    /// output. Injected rather than called directly so tests can drive the
    /// Results page from a `Database` fixture without an
    /// `AppStoragePaths.production` lookup -- the closure `production
    /// (rootURL:)` installs calls nothing but the engine. `async` so a test
    /// can hold one load open at a well-defined point and prove the store's
    /// generation guard drops it.
    public typealias StackGroupProvider = @Sendable (String) async throws -> [StackGroup]
    /// Every target folder name the library actually has on disk, used only
    /// to reconcile a project's canonical folder name with a differently
    /// spelled legacy folder (see `libraryFolder(matching:among:)`).
    public typealias LibraryTargetsProvider = @Sendable () async throws -> [String]

    private let metadata: MetadataStore?
    private let fixtureSnapshot: ResultsSnapshot?
    private let stackGroupProvider: StackGroupProvider?
    private let libraryTargetsProvider: LibraryTargetsProvider?

    public init(metadata: MetadataStore) {
        self.metadata = metadata
        fixtureSnapshot = nil
        stackGroupProvider = nil
        libraryTargetsProvider = nil
    }

    public init(
        stackGroups: @escaping StackGroupProvider,
        libraryTargets: LibraryTargetsProvider? = nil
    ) {
        metadata = nil
        fixtureSnapshot = nil
        stackGroupProvider = stackGroups
        libraryTargetsProvider = libraryTargets
    }

    private init(fixtureSnapshot: ResultsSnapshot) {
        metadata = nil
        self.fixtureSnapshot = fixtureSnapshot
        stackGroupProvider = nil
        libraryTargetsProvider = nil
    }

    /// The folder the library actually stores `requested`'s target under.
    ///
    /// Measured on the owner's real library (2026-08-17, the V2 index): the
    /// `NGC 7000` project's canonical folder name is
    /// `NGC_7000_North_America_Nebula` -- the catalog's own English name --
    /// while every one of its 62 discovered stack files sits under
    /// `NGC_7000_North_American_Nebula`. One letter, and the largest target
    /// in the library showed nothing at all. An exact string match is not a
    /// safe way to ask "which folder is this target's?".
    ///
    /// The answer comes from `TargetNameResolver`/`TargetCatalog.
    /// existingFolder(for:among:)`, which already exist for exactly this
    /// question and are what the scanner and V1 use -- deliberately NOT a
    /// fuzzy name comparison written here. Falls back to `nil` (caller uses
    /// the requested name unchanged) when the folder resolves to no catalog
    /// identity at all, e.g. a free-text project like `M_Milky_Way`.
    static func libraryFolder(matching requested: String, among folders: [String]) -> String? {
        if folders.contains(requested) { return requested }
        guard let catalogTarget = TargetCatalog.target(matchingFolderName: requested) else { return nil }
        return TargetCatalog.existingFolder(for: catalogTarget, among: folders)
    }

    /// Opens the V2 index (`AppStoragePaths.production` -> `index.sqlite`,
    /// NOT the V1 database inside the library root) once and hands
    /// `StackDiscovery` to it. Same shape as `CalibrationQuery.production`.
    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
        let config: AstroConfig = {
            var loaded = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            loaded.rootPath = rootURL.path
            return loaded
        }()
        return Self(
            stackGroups: { target in
                try StackDiscovery.groupedStacks(target: target, db: database, config: config)
            },
            libraryTargets: {
                // The distinct target folders the scanner recorded -- a
                // plain read of `files`, not a second opinion about what a
                // stack is.
                Array(Set(try database.allFiles(includeMissing: false).compactMap(\.target)))
            }
        )
    }

    /// The already-created stacks and processed outputs for one library
    /// folder, straight from `StackDiscovery.groupedStacks` -- the same
    /// engine V1's target detail page, `AppState`, and `astrotool stacks`
    /// have always used. This screen deliberately owns no recognition rule
    /// of its own: two code paths answering "is this a finished stack?" is
    /// exactly how two screens come to disagree.
    ///
    /// `async` with a synchronous body on purpose: a nonisolated `async`
    /// method does not inherit its caller's actor, so a `@MainActor` store
    /// awaiting this runs the whole library scan off the main thread.
    public func stackResults(target: String) async throws -> StackResultsSnapshot {
        guard let stackGroupProvider else { return StackResultsSnapshot(target: target, groups: []) }
        let knownFolders = try await libraryTargetsProvider?() ?? []
        let folder = Self.libraryFolder(matching: target, among: knownFolders) ?? target
        return StackResultsSnapshot(
            target: folder,
            groups: try await stackGroupProvider(folder).map(StackResultGroup.init)
        )
    }

    public static func fixture() -> Self {
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        let stackID = UUID(uuidString: "00000000-0000-0000-0000-000000000803")!
        let finalID = UUID(uuidString: "00000000-0000-0000-0000-000000000804")!
        let created = Date(timeIntervalSince1970: 1_786_147_200)
        return Self(fixtureSnapshot: .init(projectID: projectID, results: [
            .init(
                id: stackID, parentResultID: nil, kind: .stack, role: .intermediate,
                relativePath: "stacks/IC_1396/master.fit", createdAt: created,
                softwareName: "Siril", softwareVersion: "1.4",
                inputSeriesIDs: [seriesID], sourceFrameIDs: [], sourceResultIDs: [],
                calibrationAssets: ["master-dark-300s", "master-flat-SV220"]
            ),
            .init(
                id: finalID, parentResultID: stackID, kind: .processingVariant, role: .final,
                relativePath: "processed/IC_1396/final.fit", createdAt: created.addingTimeInterval(3600),
                softwareName: "PixInsight", softwareVersion: "1.9",
                inputSeriesIDs: [seriesID], sourceFrameIDs: [], sourceResultIDs: [stackID],
                calibrationAssets: ["master-dark-300s", "master-flat-SV220"]
            ),
        ], publishableResultID: finalID))
    }

    /// WARNING -- this reads two tables nothing writes. Grep the whole repo
    /// for `ResultRecord(`/`LineageEdgeRecord(` outside `MetadataStore`'s own
    /// row decoders and the test targets: zero hits, in V1 and V2 alike. No
    /// scan, import, command, or user action inserts a row into `results` or
    /// `lineage_edges`; measured on the owner's real library (2026-08-17,
    /// `Application Support/AstroTool/Libraries/<id>/metadata.sqlite`) both
    /// tables hold 0 rows. This therefore returns an empty snapshot for
    /// every project on every real install, and always has.
    ///
    /// The Results page no longer goes through here -- it uses
    /// `stackResults(target:)` (real, discovered files) instead. This
    /// remains only for the `.result(id)` inspector route and global
    /// search, which are reached exclusively FROM those same dead rows and
    /// are therefore just as unreachable. Do not build anything new on it;
    /// either give the tables a writer or delete the schema, both of which
    /// are decisions in their own right.
    public func snapshot(projectID: UUID) async throws -> ResultsSnapshot {
        if let fixtureSnapshot { return fixtureSnapshot }
        guard let metadata else { return .init(projectID: projectID, results: [], publishableResultID: nil) }
        let records = try await metadata.results(projectID: projectID)
        var details: [ResultLineageSnapshot] = []
        for record in records {
            let edges = try await metadata.lineageEdges(resultID: record.id)
            details.append(.init(
                id: record.id, parentResultID: record.parentResultID, kind: record.kind,
                role: record.role, relativePath: record.relativePath, createdAt: record.createdAt,
                softwareName: record.softwareName, softwareVersion: record.softwareVersion,
                inputSeriesIDs: edges.filter { $0.sourceKind == .series }.map(\.sourceID),
                sourceFrameIDs: edges.filter { $0.sourceKind == .frame }.map(\.sourceID),
                sourceResultIDs: edges.filter { $0.sourceKind == .result }.map(\.sourceID),
                calibrationAssets: []
            ))
        }
        let publishable = details.filter { $0.role == .final }.max { $0.createdAt < $1.createdAt }?.id
        return .init(projectID: projectID, results: details, publishableResultID: publishable)
    }

    /// Every result across every project, for library-wide search. Fixture
    /// instances (used by previews) have no metadata store and report no
    /// entries; production instances join through `MetadataStore.allResults()`.
    public func librarySearchEntries() async throws -> [ResultSearchEntry] {
        guard let metadata else { return [] }
        return try await metadata.allResults().map { summary in
            ResultSearchEntry(
                resultID: summary.result.id,
                projectID: summary.result.projectID,
                projectName: summary.projectName,
                kind: summary.result.kind,
                role: summary.result.role,
                relativePath: summary.result.relativePath,
                softwareName: summary.result.softwareName,
                softwareVersion: summary.result.softwareVersion,
                createdAt: summary.result.createdAt
            )
        }
    }
}
