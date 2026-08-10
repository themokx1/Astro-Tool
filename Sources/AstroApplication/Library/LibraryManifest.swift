import CryptoKit
import Darwin
import Foundation

public enum LibraryManifestError: Error, Equatable, Sendable {
    case invalidRoot
    case unstableRoot
    case unstableFile(relativePath: String)
}

public struct LibraryManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let relativePath: String
        public let size: Int64
        public let modifiedAtNanoseconds: Int64
        public let inode: UInt64?
        public let sha256: String

        public init(
            relativePath: String,
            size: Int64,
            modifiedAtNanoseconds: Int64,
            inode: UInt64?,
            sha256: String
        ) {
            self.relativePath = relativePath
            self.size = size
            self.modifiedAtNanoseconds = modifiedAtNanoseconds
            self.inode = inode
            self.sha256 = sha256
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public static func capture(
        root: URL,
        exclusions: Set<String> = []
    ) async throws -> Self {
        try captureSynchronously(
            root: root,
            exclusions: exclusions,
            beforeOpen: { _, _ in },
            afterHash: { _, _ in },
            beforeFinalValidation: { _ in }
        )
    }

    static func capture(
        root: URL,
        exclusions: Set<String>,
        afterHash: (_ relativePath: String, _ url: URL) throws -> Void
    ) async throws -> Self {
        try captureSynchronously(
            root: root,
            exclusions: exclusions,
            beforeOpen: { _, _ in },
            afterHash: afterHash,
            beforeFinalValidation: { _ in }
        )
    }

    static func capture(
        root: URL,
        exclusions: Set<String>,
        beforeOpen: (_ relativePath: String, _ url: URL) throws -> Void,
        afterHash: (_ relativePath: String, _ url: URL) throws -> Void
    ) async throws -> Self {
        try captureSynchronously(
            root: root,
            exclusions: exclusions,
            beforeOpen: beforeOpen,
            afterHash: afterHash,
            beforeFinalValidation: { _ in }
        )
    }

    static func capture(
        root: URL,
        exclusions: Set<String>,
        beforeOpen: (_ relativePath: String, _ url: URL) throws -> Void,
        afterHash: (_ relativePath: String, _ url: URL) throws -> Void,
        beforeFinalValidation: (_ root: URL) throws -> Void
    ) async throws -> Self {
        try captureSynchronously(
            root: root,
            exclusions: exclusions,
            beforeOpen: beforeOpen,
            afterHash: afterHash,
            beforeFinalValidation: beforeFinalValidation
        )
    }

    private static func captureSynchronously(
        root: URL,
        exclusions: Set<String>,
        beforeOpen: (_ relativePath: String, _ url: URL) throws -> Void,
        afterHash: (_ relativePath: String, _ url: URL) throws -> Void,
        beforeFinalValidation: (_ root: URL) throws -> Void
    ) throws -> Self {
        let root = root.standardizedFileURL
        guard let rootState = fileState(at: root), rootState.isDirectory, !rootState.isSymbolicLink else {
            throw LibraryManifestError.invalidRoot
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootDescriptor = openRootDirectory(canonicalRoot)
        guard rootDescriptor >= 0 else {
            throw LibraryManifestError.invalidRoot
        }
        defer { Darwin.close(rootDescriptor) }
        guard fileState(descriptor: rootDescriptor) == rootState else {
            throw LibraryManifestError.invalidRoot
        }
        let rootEntryNames: [String]
        let rootEntryIdentities: [String: FileIdentity]
        do {
            rootEntryNames = try directoryEntryNames(descriptor: rootDescriptor)
            rootEntryIdentities = try entryIdentities(
                names: rootEntryNames,
                directoryDescriptor: rootDescriptor
            )
        } catch {
            throw LibraryManifestError.unstableRoot
        }

        var entries: [Entry] = []
        try appendEntries(
            to: &entries,
            directoryDescriptor: rootDescriptor,
            rootDescriptor: rootDescriptor,
            rootURL: root,
            relativeDirectory: "",
            entryNames: rootEntryNames,
            exclusions: exclusions,
            beforeOpen: beforeOpen,
            afterHash: afterHash
        )

        try beforeFinalValidation(root)
        let reopenedRootDescriptor = openRootDirectory(canonicalRoot)
        defer {
            if reopenedRootDescriptor >= 0 { Darwin.close(reopenedRootDescriptor) }
        }
        guard
            fileState(descriptor: rootDescriptor) == rootState,
            reopenedRootDescriptor >= 0,
            fileState(descriptor: reopenedRootDescriptor) == rootState
        else {
            throw LibraryManifestError.unstableRoot
        }
        do {
            let finalNames = try directoryEntryNames(descriptor: rootDescriptor)
            let finalIdentities = try entryIdentities(
                names: finalNames,
                directoryDescriptor: rootDescriptor
            )
            guard finalNames == rootEntryNames, finalIdentities == rootEntryIdentities else {
                throw LibraryManifestError.unstableRoot
            }
        } catch let error as LibraryManifestError {
            throw error
        } catch {
            throw LibraryManifestError.unstableRoot
        }

        entries.sort { $0.relativePath < $1.relativePath }
        return Self(entries: entries)
    }

    private static func appendEntries(
        to entries: inout [Entry],
        directoryDescriptor: Int32,
        rootDescriptor: Int32,
        rootURL: URL,
        relativeDirectory: String,
        entryNames: [String]? = nil,
        exclusions: Set<String>,
        beforeOpen: (_ relativePath: String, _ url: URL) throws -> Void,
        afterHash: (_ relativePath: String, _ url: URL) throws -> Void
    ) throws {
        let names: [String]
        if let entryNames {
            names = entryNames
        } else {
            names = try directoryEntryNames(descriptor: directoryDescriptor)
        }
        for name in names {
            if relativeDirectory.isEmpty && exclusions.contains(name) {
                continue
            }
            let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
            guard let observed = fileState(name: name, relativeTo: directoryDescriptor) else {
                throw LibraryManifestError.unstableFile(relativePath: relativePath)
            }
            if observed.isSymbolicLink {
                continue
            }
            if observed.isDirectory {
                let childDescriptor = openChildDirectory(name: name, relativeTo: directoryDescriptor)
                guard
                    childDescriptor >= 0,
                    fileState(descriptor: childDescriptor) == observed
                else {
                    if childDescriptor >= 0 { Darwin.close(childDescriptor) }
                    throw LibraryManifestError.unstableFile(relativePath: relativePath)
                }
                do {
                    try appendEntries(
                        to: &entries,
                        directoryDescriptor: childDescriptor,
                        rootDescriptor: rootDescriptor,
                        rootURL: rootURL,
                        relativeDirectory: relativePath,
                        entryNames: nil,
                        exclusions: exclusions,
                        beforeOpen: beforeOpen,
                        afterHash: afterHash
                    )
                } catch {
                    Darwin.close(childDescriptor)
                    throw error
                }
                let remainsStable = (
                    fileState(descriptor: childDescriptor) == observed,
                    fileState(name: name, relativeTo: directoryDescriptor) == observed
                )
                Darwin.close(childDescriptor)
                guard remainsStable.0 && remainsStable.1 else {
                    throw LibraryManifestError.unstableFile(relativePath: relativePath)
                }
                continue
            }
            guard observed.isRegularFile else {
                continue
            }

            let url = rootURL.appendingPathComponent(relativePath)
            entries.append(try hashEntry(
                at: url,
                rootDescriptor: rootDescriptor,
                relativePath: relativePath,
                observed: observed,
                beforeOpen: beforeOpen,
                afterHash: afterHash
            ))
        }
    }

    private static func hashEntry(
        at url: URL,
        rootDescriptor: Int32,
        relativePath: String,
        observed: FileState,
        beforeOpen: (_ relativePath: String, _ url: URL) throws -> Void,
        afterHash: (_ relativePath: String, _ url: URL) throws -> Void
    ) throws -> Entry {
        try beforeOpen(relativePath, url)
        let descriptor = openFile(relativePath: relativePath, rootDescriptor: rootDescriptor)
        guard descriptor >= 0 else {
            throw LibraryManifestError.unstableFile(relativePath: relativePath)
        }
        defer { Darwin.close(descriptor) }

        guard
            let opened = fileState(descriptor: descriptor),
            opened.isRegularFile,
            opened == observed
        else {
            throw LibraryManifestError.unstableFile(relativePath: relativePath)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            hasher.update(data: Data(buffer[0..<count]))
        }

        try afterHash(relativePath, url)
        let reopenedDescriptor = openFile(relativePath: relativePath, rootDescriptor: rootDescriptor)
        defer {
            if reopenedDescriptor >= 0 { Darwin.close(reopenedDescriptor) }
        }
        guard
            let openedAfter = fileState(descriptor: descriptor),
            reopenedDescriptor >= 0,
            let pathAfter = fileState(descriptor: reopenedDescriptor),
            openedAfter == observed,
            pathAfter == observed
        else {
            throw LibraryManifestError.unstableFile(relativePath: relativePath)
        }

        return Entry(
            relativePath: relativePath,
            size: observed.size,
            modifiedAtNanoseconds: observed.modifiedAtNanoseconds,
            inode: observed.inode,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return names.sorted()
    }

    private static func openChildDirectory(name: String, relativeTo descriptor: Int32) -> Int32 {
        name.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
    }

    private static func openFile(relativePath: String, rootDescriptor: Int32) -> Int32 {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else {
            return -1
        }
        var descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else { return -1 }

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isLast ? O_NONBLOCK : O_DIRECTORY)
            let next = String(component).withCString { Darwin.openat(descriptor, $0, flags) }
            Darwin.close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        return descriptor
    }

    private static func openRootDirectory(_ root: URL) -> Int32 {
        root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
    }

    private static func entryIdentities(
        names: [String],
        directoryDescriptor: Int32
    ) throws -> [String: FileIdentity] {
        var identities: [String: FileIdentity] = [:]
        for name in names {
            guard let state = fileState(name: name, relativeTo: directoryDescriptor) else {
                throw LibraryManifestError.unstableRoot
            }
            identities[name] = state.identity
        }
        return identities
    }

    private static func fileState(at url: URL) -> FileState? {
        var info = Darwin.stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &info)
        }
        guard result == 0 else { return nil }
        return FileState(info)
    }

    private static func fileState(descriptor: Int32) -> FileState? {
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { return nil }
        return FileState(info)
    }

    private static func fileState(name: String, relativeTo descriptor: Int32) -> FileState? {
        var info = Darwin.stat()
        let result = name.withCString {
            Darwin.fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { return nil }
        return FileState(info)
    }
}

private struct FileState: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: mode_t
    let size: Int64
    let modifiedAtNanoseconds: Int64

    var isDirectory: Bool {
        mode & S_IFMT == S_IFDIR
    }

    var isRegularFile: Bool {
        mode & S_IFMT == S_IFREG
    }

    var isSymbolicLink: Bool {
        mode & S_IFMT == S_IFLNK
    }

    var identity: FileIdentity {
        FileIdentity(device: device, inode: inode, fileType: mode & S_IFMT)
    }

    init(_ info: Darwin.stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        mode = info.st_mode
        size = info.st_size
        modifiedAtNanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(info.st_mtimespec.tv_nsec)
    }
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let fileType: mode_t
}
