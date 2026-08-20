import AstroCore
import Darwin
import Foundation

public enum LibrarySessionError: Error, Equatable, Sendable {
    case invalidRoot
    case libraryIdentityMismatch
    case indexDestinationInsideLibrary
    case invalidIndexDestination
    case indexDatabaseIsSymbolicLink
    case cannotCreateIndexParent
    case unsafeIndexParent
    case unsafeIndexDatabase
    case indexDestinationChanged
}

public struct LibraryScanProgress: Equatable, Sendable {
    public let scanned: Int
    public let total: Int?
    public let fraction: Double?

    public init(scanned: Int, total: Int?) {
        let safeTotal = total.map { max(0, $0) }
        let safeScanned = safeTotal.map { min(max(0, scanned), $0) } ?? max(0, scanned)
        self.scanned = safeScanned
        self.total = safeTotal
        self.fraction = safeTotal.map { total in
            total == 0 ? 1 : Double(safeScanned) / Double(total)
        }
    }
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
        try await open(
            rootURL: rootURL,
            storage: storage,
            beforeIndexParentOpen: {},
            beforeDatabaseOpen: {}
        )
    }

    static func open(
        rootURL: URL,
        storage: AppStoragePaths,
        beforeIndexParentOpen: @Sendable () throws -> Void = {},
        beforeDatabaseOpen: @Sendable () throws -> Void
    ) async throws -> LibrarySession {
        let root = try validatedRoot(rootURL)
        let identity = LibraryIdentity(rootURL: root)
        guard storage.libraryID == identity else {
            throw LibrarySessionError.libraryIdentityMismatch
        }

        let indexDatabase = storage.indexDatabase.standardizedFileURL
        try validateIndexDestination(indexDatabase, relativeTo: root)
        let canonicalParent = try canonicalIntendedPath(
            indexDatabase.deletingLastPathComponent()
        )
        guard !isContained(canonicalParent, in: canonicalPath(root)) else {
            throw LibrarySessionError.indexDestinationInsideLibrary
        }
        try beforeIndexParentOpen()

        let parentDescriptor = try openIndexParent(canonicalParent)
        defer { Darwin.close(parentDescriptor) }
        try validateIndexDestination(indexDatabase, relativeTo: root)
        _ = try safeParentState(descriptor: parentDescriptor)
        let databaseDescriptor = try openIndexDatabase(
            named: indexDatabase.lastPathComponent,
            relativeTo: parentDescriptor
        )
        defer { Darwin.close(databaseDescriptor) }
        let parentState = try safeParentState(descriptor: parentDescriptor)
        let databaseState = try safeDatabaseState(descriptor: databaseDescriptor)
        let canonicalIndexDatabase = canonicalParent
            .appendingPathComponent(indexDatabase.lastPathComponent)

        let database = try Database(
            confinedIndexPath: canonicalIndexDatabase.path,
            beforeOpen: beforeDatabaseOpen,
            validateBeforeUse: {
                try validatePinnedDestination(
                    indexDatabase,
                    relativeTo: root,
                    parentDescriptor: parentDescriptor,
                    expectedParent: parentState,
                    databaseDescriptor: databaseDescriptor,
                    expectedDatabase: databaseState
                )
            }
        )
        let scanner = LibraryScanner(config: AstroConfig(rootPath: root.path), db: database)
        return LibrarySession(identity: identity, scanner: scanner, database: database)
    }

    public func scan() async throws -> LibrarySnapshot {
        _ = try scanner.scan()
        return try nextSnapshot()
    }

    public func scan(
        progress: @escaping @Sendable (LibraryScanProgress) -> Void
    ) async throws -> LibrarySnapshot {
        _ = try scanner.scan(progressUpdate: { update in
            progress(LibraryScanProgress(scanned: update.scanned, total: update.total))
        }, shouldCancel: { Task.isCancelled })
        return try nextSnapshot()
    }

    private func nextSnapshot() throws -> LibrarySnapshot {
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

    private struct FileState: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let owner: UInt32
        let linkCount: UInt64

        var fileType: UInt32 { mode & UInt32(S_IFMT) }
        var isGroupOrWorldWritable: Bool {
            mode & UInt32(S_IWGRP | S_IWOTH) != 0
        }

        init(_ status: stat) {
            self.device = UInt64(status.st_dev)
            self.inode = UInt64(status.st_ino)
            self.mode = UInt32(status.st_mode)
            self.owner = UInt32(status.st_uid)
            self.linkCount = UInt64(status.st_nlink)
        }
    }

    private static func openIndexParent(_ parent: URL) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw LibrarySessionError.unsafeIndexParent }

        do {
            for component in parent.standardizedFileURL.pathComponents.dropFirst() {
                let nextDescriptor = try component.withCString { name -> Int32 in
                    var opened = Darwin.openat(
                        descriptor,
                        name,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                    if opened < 0, errno == ENOENT {
                        let created = Darwin.mkdirat(
                            descriptor,
                            name,
                            mode_t(S_IRWXU)
                        )
                        guard created == 0 || errno == EEXIST else {
                            throw LibrarySessionError.cannotCreateIndexParent
                        }
                        opened = Darwin.openat(
                            descriptor,
                            name,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard opened >= 0 else {
                        throw LibrarySessionError.unsafeIndexParent
                    }
                    return opened
                }
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func canonicalIntendedPath(_ url: URL) throws -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []

        while true {
            if let resolved = Darwin.realpath(existingAncestor.path, nil) {
                defer { Darwin.free(resolved) }
                return missingComponents.reversed().reduce(
                    URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                ) { partial, component in
                    partial.appendingPathComponent(component, isDirectory: true)
                }
            }
            guard existingAncestor.path != "/" else {
                throw LibrarySessionError.unsafeIndexParent
            }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }
    }

    private static func openIndexDatabase(named name: String, relativeTo parent: Int32) throws -> Int32 {
        let descriptor = name.withCString { path in
            Darwin.openat(
                parent,
                path,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw LibrarySessionError.unsafeIndexDatabase
        }
        return descriptor
    }

    private static func safeParentState(descriptor: Int32) throws -> FileState {
        let state = try fileState(descriptor: descriptor)
        guard
            state.fileType == UInt32(S_IFDIR),
            state.owner == UInt32(Darwin.geteuid()),
            !state.isGroupOrWorldWritable
        else {
            throw LibrarySessionError.unsafeIndexParent
        }
        return state
    }

    private static func safeDatabaseState(descriptor: Int32) throws -> FileState {
        let state = try fileState(descriptor: descriptor)
        guard
            state.fileType == UInt32(S_IFREG),
            state.owner == UInt32(Darwin.geteuid()),
            state.linkCount == 1,
            !state.isGroupOrWorldWritable
        else {
            throw LibrarySessionError.unsafeIndexDatabase
        }
        return state
    }

    private static func validatePinnedDestination(
        _ indexDatabase: URL,
        relativeTo root: URL,
        parentDescriptor: Int32,
        expectedParent: FileState,
        databaseDescriptor: Int32,
        expectedDatabase: FileState
    ) throws {
        try validateIndexDestination(indexDatabase, relativeTo: root)
        guard try fileState(descriptor: parentDescriptor) == expectedParent else {
            throw LibrarySessionError.unsafeIndexParent
        }
        guard try fileState(at: indexDatabase.deletingLastPathComponent()) == expectedParent else {
            throw LibrarySessionError.indexDestinationChanged
        }
        guard try fileState(descriptor: databaseDescriptor) == expectedDatabase else {
            throw LibrarySessionError.unsafeIndexDatabase
        }
        guard try fileState(at: indexDatabase) == expectedDatabase else {
            throw LibrarySessionError.indexDestinationChanged
        }
    }

    private static func fileState(descriptor: Int32) throws -> FileState {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw LibrarySessionError.indexDestinationChanged
        }
        return FileState(status)
    }

    private static func fileState(at url: URL) throws -> FileState {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            throw LibrarySessionError.indexDestinationChanged
        }
        return FileState(status)
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
