import CryptoKit
import Darwin
import Foundation

public enum LibraryManifestError: Error, Equatable, Sendable {
    case invalidRoot
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
        try captureSynchronously(root: root, exclusions: exclusions) { _, _ in }
    }

    static func capture(
        root: URL,
        exclusions: Set<String>,
        afterHash: (_ relativePath: String, _ url: URL) throws -> Void
    ) async throws -> Self {
        try captureSynchronously(root: root, exclusions: exclusions, afterHash: afterHash)
    }

    private static func captureSynchronously(
        root: URL,
        exclusions: Set<String>,
        afterHash: (_ relativePath: String, _ url: URL) throws -> Void
    ) throws -> Self {
        let root = root.standardizedFileURL
        guard let rootState = fileState(at: root), rootState.isDirectory, !rootState.isSymbolicLink else {
            throw LibraryManifestError.invalidRoot
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LibraryManifestError.invalidRoot
        }

        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let relativePath = normalizedRelativePath(for: url, root: root)
            let topLevelComponent = relativePath.split(separator: "/", maxSplits: 1).first.map(String.init)
            if topLevelComponent.map(exclusions.contains) == true {
                enumerator.skipDescendants()
                continue
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                throw LibraryManifestError.unstableFile(relativePath: relativePath)
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }

            entries.append(try hashEntry(at: url, relativePath: relativePath, afterHash: afterHash))
        }
        if let enumerationError {
            throw enumerationError
        }

        entries.sort { $0.relativePath < $1.relativePath }
        return Self(entries: entries)
    }

    private static func hashEntry(
        at url: URL,
        relativePath: String,
        afterHash: (_ relativePath: String, _ url: URL) throws -> Void
    ) throws -> Entry {
        guard let before = fileState(at: url), before.isRegularFile, !before.isSymbolicLink else {
            throw LibraryManifestError.unstableFile(relativePath: relativePath)
        }

        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw LibraryManifestError.unstableFile(relativePath: relativePath)
        }
        defer { Darwin.close(descriptor) }

        guard let opened = fileState(descriptor: descriptor), opened == before else {
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
        guard
            let openedAfter = fileState(descriptor: descriptor),
            let pathAfter = fileState(at: url),
            openedAfter == before,
            pathAfter == before
        else {
            throw LibraryManifestError.unstableFile(relativePath: relativePath)
        }

        return Entry(
            relativePath: relativePath,
            size: before.size,
            modifiedAtNanoseconds: before.modifiedAtNanoseconds,
            inode: before.inode,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func normalizedRelativePath(for url: URL, root: URL) -> String {
        let rootPath = root.path == "/" ? "" : root.path
        return String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
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

    init(_ info: Darwin.stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        mode = info.st_mode
        size = info.st_size
        modifiedAtNanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(info.st_mtimespec.tv_nsec)
    }
}
