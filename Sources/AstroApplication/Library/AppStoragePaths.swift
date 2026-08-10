import Foundation

public enum AppStoragePathsError: Error, Equatable, Sendable {
    case storageRootInsideLibrary
    case libraryIdentityMismatch
    case applicationSupportUnavailable
    case cachesUnavailable
}

public struct AppStoragePaths: Sendable {
    public let metadataDatabase: URL
    public let indexDatabase: URL
    public let thumbnails: URL
    public let migration: URL

    public var allURLs: [URL] {
        [metadataDatabase, indexDatabase, thumbnails, migration]
    }

    public init(
        applicationSupport: URL,
        caches: URL,
        libraryID: LibraryIdentity,
        libraryRoot: URL
    ) throws {
        guard libraryID == LibraryIdentity(rootURL: libraryRoot) else {
            throw AppStoragePathsError.libraryIdentityMismatch
        }

        let resolvedLibraryRoot = Self.canonicalDirectory(libraryRoot)
        for storageRoot in [applicationSupport, caches] {
            if Self.isContained(Self.canonicalDirectory(storageRoot), in: resolvedLibraryRoot) {
                throw AppStoragePathsError.storageRootInsideLibrary
            }
        }

        let appLibrary = applicationSupport.standardizedFileURL
            .appendingPathComponent("AstroTool", isDirectory: true)
            .appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(libraryID.id, isDirectory: true)
        let cacheLibrary = caches.standardizedFileURL
            .appendingPathComponent("AstroTool", isDirectory: true)
            .appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(libraryID.id, isDirectory: true)

        self.metadataDatabase = appLibrary.appendingPathComponent("metadata.sqlite")
        self.indexDatabase = cacheLibrary.appendingPathComponent("index.sqlite")
        self.thumbnails = cacheLibrary.appendingPathComponent("thumbnails", isDirectory: true)
        self.migration = appLibrary.appendingPathComponent("migration", isDirectory: true)
    }

    public static func production(
        libraryID: LibraryIdentity,
        libraryRoot: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppStoragePathsError.applicationSupportUnavailable
        }
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw AppStoragePathsError.cachesUnavailable
        }
        return try Self(
            applicationSupport: applicationSupport,
            caches: caches,
            libraryID: libraryID,
            libraryRoot: libraryRoot
        )
    }

    private static func canonicalDirectory(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        if candidatePath == rootPath {
            return true
        }
        let prefix = rootPath == "/" ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }
}
