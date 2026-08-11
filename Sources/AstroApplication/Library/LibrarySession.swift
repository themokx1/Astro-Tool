import AstroCore
import Foundation

public enum LibrarySessionError: Error, Equatable, Sendable {
    case invalidRoot
    case libraryIdentityMismatch
    case indexDestinationInsideLibrary
    case invalidIndexDestination
    case indexDatabaseIsSymbolicLink
    case cannotCreateIndexParent
}

public actor LibrarySession {
    public nonisolated let identity: LibraryIdentity
    public private(set) var accessMode: LibraryAccessMode

    private let scanner: LibraryScanner
    private let database: Database
    private var revision: UInt64

    private init(identity: LibraryIdentity, scanner: LibraryScanner, database: Database) {
        self.identity = identity
        self.accessMode = .readOnly
        self.scanner = scanner
        self.database = database
        self.revision = 0
    }

    public static func open(rootURL: URL, storage: AppStoragePaths) async throws -> LibrarySession {
        let root = try validatedRoot(rootURL)
        let identity = LibraryIdentity(rootURL: root)
        guard storage.libraryID == identity else {
            throw LibrarySessionError.libraryIdentityMismatch
        }

        let indexDatabase = storage.indexDatabase.standardizedFileURL
        try validateIndexDestination(indexDatabase, relativeTo: root)
        do {
            try FileManager.default.createDirectory(
                at: indexDatabase.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw LibrarySessionError.cannotCreateIndexParent
        }
        try validateIndexDestination(indexDatabase, relativeTo: root)

        let database = try Database(path: indexDatabase.path)
        let scanner = LibraryScanner(config: AstroConfig(rootPath: root.path), db: database)
        return LibrarySession(identity: identity, scanner: scanner, database: database)
    }

    public func scan() async throws -> LibrarySnapshot {
        _ = try scanner.scan()
        let counts = try database.libraryIndexCounts()
        let nextRevision = revision + 1
        revision = nextRevision
        return LibrarySnapshot(
            libraryID: identity,
            revision: nextRevision,
            projectCount: counts.projectCount,
            nightCount: counts.nightCount,
            frameCount: counts.frameCount
        )
    }

    private static func validatedRoot(_ rootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
            attributes[.type] as? FileAttributeType == .typeDirectory
        else {
            throw LibrarySessionError.invalidRoot
        }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func validateIndexDestination(_ indexDatabase: URL, relativeTo root: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: indexDatabase.path) {
            guard let fileType = attributes[.type] as? FileAttributeType else {
                throw LibrarySessionError.invalidIndexDestination
            }
            if fileType == .typeSymbolicLink {
                throw LibrarySessionError.indexDatabaseIsSymbolicLink
            }
            guard fileType == .typeRegular else {
                throw LibrarySessionError.invalidIndexDestination
            }
        }

        let canonicalDestination = canonicalPath(indexDatabase)
        let canonicalRoot = canonicalPath(root)
        guard !isContained(canonicalDestination, in: canonicalRoot) else {
            throw LibrarySessionError.indexDestinationInsideLibrary
        }

        let parent = indexDatabase.deletingLastPathComponent()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw LibrarySessionError.invalidIndexDestination
            }
        }
    }

    private static func canonicalPath(_ url: URL) -> URL {
        url.standardizedFileURL.pathComponents.dropFirst().reduce(
            URL(fileURLWithPath: "/", isDirectory: true)
        ) { resolvedPrefix, component in
            resolvedPrefix
                .appendingPathComponent(component)
                .resolvingSymlinksInPath()
        }
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        if candidatePath == rootPath { return true }
        let prefix = rootPath == "/" ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }
}
