import Foundation

public enum AppStoragePathsError: Error, Equatable, Sendable {
    case storageRootInsideLibrary
    case storageDestinationInsideLibrary
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

        let metadataDatabase = appLibrary.appendingPathComponent("metadata.sqlite")
        let indexDatabase = cacheLibrary.appendingPathComponent("index.sqlite")
        let thumbnails = cacheLibrary.appendingPathComponent("thumbnails", isDirectory: true)
        let migration = appLibrary.appendingPathComponent("migration", isDirectory: true)
        let finalDestinations = [appLibrary, cacheLibrary, metadataDatabase, indexDatabase, thumbnails, migration]
        guard !finalDestinations.contains(where: {
            Self.isContained(Self.canonicalDirectory($0), in: resolvedLibraryRoot)
        }) else {
            throw AppStoragePathsError.storageDestinationInsideLibrary
        }

        self.metadataDatabase = metadataDatabase
        self.indexDatabase = indexDatabase
        self.thumbnails = thumbnails
        self.migration = migration
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
        if candidatePath == rootPath {
            return true
        }
        let prefix = rootPath == "/" ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }
}
