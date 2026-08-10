import AstroApplication
import CryptoKit
import Foundation
import Testing

@Suite("App-owned library storage paths")
struct AppStoragePathsTests {
    private let applicationSupport = URL(fileURLWithPath: "/tmp/AstroToolAppSupport", isDirectory: true)
    private let caches = URL(fileURLWithPath: "/tmp/AstroToolCache", isDirectory: true)
    private let imageRoot = URL(fileURLWithPath: "/Volumes/Fixture/Astro", isDirectory: true)

    @Test("Library identity is stable for equivalent canonical URLs")
    func stableLibraryIdentity() throws {
        let disk = FileManager.default
        let fixture = disk.temporaryDirectory
            .appendingPathComponent("AstroToolStableIdentity-\(UUID().uuidString)", isDirectory: true)
        let libraryRoot = fixture.appendingPathComponent("Library", isDirectory: true)
        try disk.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        defer { try? disk.removeItem(at: fixture) }

        let identity = LibraryIdentity(rootURL: libraryRoot)
        let equivalent = LibraryIdentity(
            rootURL: libraryRoot
                .appendingPathComponent("subdirectory", isDirectory: true)
                .appendingPathComponent("..", isDirectory: true)
        )

        #expect(identity == equivalent)
        #expect(identity.id.count == 64)
        #expect(identity.id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("Encoded identity does not include the plaintext library root")
    func doesNotEncodePlaintextRoot() throws {
        let identity = LibraryIdentity(rootURL: imageRoot)

        let data = try JSONEncoder().encode(identity)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(LibraryIdentity.self, from: data)

        #expect(json.contains(identity.id))
        #expect(!json.contains(imageRoot.path))
        #expect(!json.contains("Volumes"))
        #expect(decoded == identity)
    }

    @Test("Decoded identity remains usable with a separately supplied library root")
    func decodedIdentityConstructsStoragePaths() throws {
        let identity = LibraryIdentity(rootURL: imageRoot)
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(LibraryIdentity.self, from: data)

        let paths = try AppStoragePaths(
            applicationSupport: applicationSupport,
            caches: caches,
            libraryID: decoded,
            libraryRoot: imageRoot
        )

        #expect(paths.metadataDatabase.path ==
            "/tmp/AstroToolAppSupport/AstroTool/Libraries/\(identity.id)/metadata.sqlite")
        #expect(paths.indexDatabase.path ==
            "/tmp/AstroToolCache/AstroTool/Libraries/\(identity.id)/index.sqlite")
    }

    @Test("Malformed encoded library identities are rejected")
    func rejectsMalformedEncodedIdentities() throws {
        let malformedIDs = [
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ]

        for id in malformedIDs {
            let data = try JSONEncoder().encode(["id": id])
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LibraryIdentity.self, from: data)
            }
        }
    }

    @Test("Library identity resolves symbolic links")
    func identityResolvesSymbolicLinks() throws {
        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("AstroToolLibraryIdentity-\(UUID().uuidString)", isDirectory: true)
        let realRoot = fixtureRoot.appendingPathComponent("RealLibrary", isDirectory: true)
        let symlinkRoot = fixtureRoot.appendingPathComponent("LinkedLibrary", isDirectory: true)
        try fileManager.createDirectory(at: realRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }
        try fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)

        #expect(LibraryIdentity(rootURL: symlinkRoot) == LibraryIdentity(rootURL: realRoot))
    }

    @Test("Injected roots produce exact app-owned paths")
    func exactInjectedPaths() throws {
        let identity = LibraryIdentity(rootURL: imageRoot)
        let paths = try AppStoragePaths(
            applicationSupport: applicationSupport,
            caches: caches,
            libraryID: identity,
            libraryRoot: imageRoot
        )
        let appLibrary = applicationSupport
            .appendingPathComponent("AstroTool/Libraries", isDirectory: true)
            .appendingPathComponent(identity.id, isDirectory: true)
        let cacheLibrary = caches
            .appendingPathComponent("AstroTool/Libraries", isDirectory: true)
            .appendingPathComponent(identity.id, isDirectory: true)

        #expect(paths.metadataDatabase == appLibrary.appendingPathComponent("metadata.sqlite"))
        #expect(paths.migration == appLibrary.appendingPathComponent("migration", isDirectory: true))
        #expect(paths.indexDatabase == cacheLibrary.appendingPathComponent("index.sqlite"))
        #expect(paths.thumbnails == cacheLibrary.appendingPathComponent("thumbnails", isDirectory: true))
        #expect(paths.allURLs == [
            paths.metadataDatabase,
            paths.indexDatabase,
            paths.thumbnails,
            paths.migration,
        ])
    }

    @Test("Every writable URL stays outside the image library")
    func writableURLsStayInInjectedRoots() throws {
        let paths = try AppStoragePaths(
            applicationSupport: applicationSupport,
            caches: caches,
            libraryID: LibraryIdentity(rootURL: imageRoot),
            libraryRoot: imageRoot
        )

        for url in paths.allURLs {
            #expect(isContained(url, in: applicationSupport) || isContained(url, in: caches))
            #expect(!isContained(url, in: imageRoot))
        }
    }

    @Test("Production paths use FileManager roots without creating storage")
    func productionPathsAreInjectableAndComputeOnly() throws {
        let disk = FileManager.default
        let fixtureRoot = disk.temporaryDirectory
            .appendingPathComponent("AstroToolStorageProbe-\(UUID().uuidString)", isDirectory: true)
        try disk.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
        defer { try? disk.removeItem(at: fixtureRoot) }

        let sentinelDirectory = fixtureRoot
            .appendingPathComponent("sentinel-tree", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        try disk.createDirectory(at: sentinelDirectory, withIntermediateDirectories: true)
        let marker = sentinelDirectory.appendingPathComponent("sentinel.bin")
        let sentinelBytes = Data("unchanged sentinel bytes".utf8)
        #expect(disk.createFile(atPath: marker.path, contents: sentinelBytes))
        let applicationSupportParent = fixtureRoot.appendingPathComponent("app-parent", isDirectory: true)
        let cachesParent = fixtureRoot.appendingPathComponent("cache-parent", isDirectory: true)
        let injectedApplicationSupport = applicationSupportParent
            .appendingPathComponent("Application Support", isDirectory: true)
        let injectedCaches = cachesParent.appendingPathComponent("Caches", isDirectory: true)
        let fileManager = StorageRootFileManager(
            applicationSupport: injectedApplicationSupport,
            caches: injectedCaches
        )
        let manifestBefore = try directoryManifest(at: fixtureRoot, fileManager: disk)
        #expect(!disk.fileExists(atPath: applicationSupportParent.path))
        #expect(!disk.fileExists(atPath: cachesParent.path))
        #expect(!disk.fileExists(atPath: injectedApplicationSupport.path))
        #expect(!disk.fileExists(atPath: injectedCaches.path))

        let identity = LibraryIdentity(rootURL: imageRoot)
        let expected = try AppStoragePaths(
            applicationSupport: injectedApplicationSupport,
            caches: injectedCaches,
            libraryID: identity,
            libraryRoot: imageRoot
        )

        let paths = try AppStoragePaths.production(
            libraryID: identity,
            libraryRoot: imageRoot,
            fileManager: fileManager
        )

        #expect(paths.allURLs == expected.allURLs)
        #expect(!disk.fileExists(atPath: applicationSupportParent.path))
        #expect(!disk.fileExists(atPath: cachesParent.path))
        #expect(!disk.fileExists(atPath: injectedApplicationSupport.path))
        #expect(!disk.fileExists(atPath: injectedCaches.path))
        #expect(try Data(contentsOf: marker) == sentinelBytes)
        #expect(try directoryManifest(at: fixtureRoot, fileManager: disk) == manifestBefore)
    }

    @Test("Storage roots nested inside the image library are rejected")
    func rejectsStorageInsideLibrary() {
        let identity = LibraryIdentity(rootURL: imageRoot)
        let nested = imageRoot.appendingPathComponent("AppOwned", isDirectory: true)

        #expect(throws: AppStoragePathsError.storageRootInsideLibrary) {
            try AppStoragePaths(
                applicationSupport: nested,
                caches: caches,
                libraryID: identity,
                libraryRoot: imageRoot
            )
        }
        #expect(throws: AppStoragePathsError.storageRootInsideLibrary) {
            try AppStoragePaths(
                applicationSupport: applicationSupport,
                caches: nested,
                libraryID: identity,
                libraryRoot: imageRoot
            )
        }
    }

    @Test("Final app and cache library directories inside the image library are rejected")
    func rejectsFinalLibraryDirectoriesInsideImageLibrary() {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroToolFinalDestination-\(UUID().uuidString)", isDirectory: true)
        let applicationSupport = fixture.appendingPathComponent("support", isDirectory: true)
        let appNestedLibrary = applicationSupport.appendingPathComponent("AstroTool", isDirectory: true)
        let caches = fixture.appendingPathComponent("caches", isDirectory: true)
        let cacheNestedLibrary = caches.appendingPathComponent("AstroTool", isDirectory: true)

        #expect(throws: AppStoragePathsError.storageDestinationInsideLibrary) {
            try AppStoragePaths(
                applicationSupport: applicationSupport,
                caches: caches,
                libraryID: LibraryIdentity(rootURL: appNestedLibrary),
                libraryRoot: appNestedLibrary
            )
        }
        #expect(throws: AppStoragePathsError.storageDestinationInsideLibrary) {
            try AppStoragePaths(
                applicationSupport: applicationSupport,
                caches: caches,
                libraryID: LibraryIdentity(rootURL: cacheNestedLibrary),
                libraryRoot: cacheNestedLibrary
            )
        }
    }

    @Test("Symlinked final app and cache destinations inside the image library are rejected")
    func rejectsSymlinkedFinalDestinationsInsideImageLibrary() throws {
        let disk = FileManager.default
        let fixture = disk.temporaryDirectory
            .appendingPathComponent("AstroToolSymlinkDestination-\(UUID().uuidString)", isDirectory: true)
        let libraryRoot = fixture.appendingPathComponent("library", isDirectory: true)
        let applicationSupport = fixture.appendingPathComponent("support", isDirectory: true)
        let caches = fixture.appendingPathComponent("caches", isDirectory: true)
        try disk.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try disk.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try disk.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? disk.removeItem(at: fixture) }
        try disk.createSymbolicLink(
            at: applicationSupport.appendingPathComponent("AstroTool", isDirectory: true),
            withDestinationURL: libraryRoot
        )
        try disk.createSymbolicLink(
            at: caches.appendingPathComponent("AstroTool", isDirectory: true),
            withDestinationURL: libraryRoot
        )
        let identity = LibraryIdentity(rootURL: libraryRoot)
        let safeCaches = fixture.appendingPathComponent("safe-caches", isDirectory: true)
        let safeSupport = fixture.appendingPathComponent("safe-support", isDirectory: true)

        #expect(throws: AppStoragePathsError.storageDestinationInsideLibrary) {
            try AppStoragePaths(
                applicationSupport: applicationSupport,
                caches: safeCaches,
                libraryID: identity,
                libraryRoot: libraryRoot
            )
        }
        #expect(throws: AppStoragePathsError.storageDestinationInsideLibrary) {
            try AppStoragePaths(
                applicationSupport: safeSupport,
                caches: caches,
                libraryID: identity,
                libraryRoot: libraryRoot
            )
        }
    }

    @Test("Library identity must describe the supplied library root")
    func rejectsMismatchedLibraryIdentityAndRoot() {
        let identity = LibraryIdentity(rootURL: imageRoot)
        let differentRoot = URL(fileURLWithPath: "/Volumes/Fixture/Other", isDirectory: true)

        #expect(throws: AppStoragePathsError.libraryIdentityMismatch) {
            try AppStoragePaths(
                applicationSupport: applicationSupport,
                caches: caches,
                libraryID: identity,
                libraryRoot: differentRoot
            )
        }
    }

    private func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func directoryManifest(at root: URL, fileManager: FileManager) throws -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = try #require(fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ))
        var manifest: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate?
                .timeIntervalSinceReferenceDate.bitPattern ?? 0
            let contentHash: String
            if values.isDirectory == true {
                contentHash = "-"
            } else {
                contentHash = SHA256.hash(data: try Data(contentsOf: url))
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
            manifest.append("\(relativePath)|\(size)|\(modified)|\(contentHash)")
        }
        return manifest.sorted()
    }
}

private final class StorageRootFileManager: FileManager, @unchecked Sendable {
    private let applicationSupport: URL
    private let caches: URL

    init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        switch directory {
        case .applicationSupportDirectory:
            [applicationSupport]
        case .cachesDirectory:
            [caches]
        default:
            []
        }
    }
}
