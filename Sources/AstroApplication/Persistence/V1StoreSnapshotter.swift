import AstroCore
import CryptoKit
import Darwin
import Foundation

public enum V1StoreSnapshotError: Error, Equatable, Sendable {
    case invalidSourceDirectory
    case missingDatabase
    case symbolicLink(String)
    case unsafeEntry(String)
    case sourceChanged
}

public struct V1SourceManifest: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let relativePath: String
        public let byteCount: Int64
        public let sha256: String
    }

    public let entries: [Entry]

    public static func capture(directory: URL) throws -> V1SourceManifest {
        let root = directory.standardizedFileURL
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw V1StoreSnapshotError.invalidSourceDirectory }
        defer { Darwin.close(rootDescriptor) }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw V1StoreSnapshotError.invalidSourceDirectory
        }

        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let relativePath = relativePath(of: url, below: root)
            // SQLite's shared-memory file contains transient reader-lock and
            // wal-index bytes that a read-only connection is allowed to
            // update. It is not durable user data; the main DB and WAL are.
            if relativePath == "astrotool.sqlite-shm" { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw V1StoreSnapshotError.symbolicLink(relativePath)
            }
            guard values.isRegularFile == true else { continue }
            let digest = try hashFile(relativePath: relativePath, rootDescriptor: rootDescriptor)
            entries.append(Entry(
                relativePath: relativePath,
                byteCount: digest.byteCount,
                sha256: digest.sha256
            ))
        }
        return V1SourceManifest(entries: entries.sorted { $0.relativePath < $1.relativePath })
    }

    private static func relativePath(of url: URL, below root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
    }

    private static func hashFile(
        relativePath: String,
        rootDescriptor: Int32
    ) throws -> (byteCount: Int64, sha256: String) {
        try withFileDescriptor(relativePath: relativePath, rootDescriptor: rootDescriptor) { file in
            var hasher = SHA256()
            var byteCount: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(file, $0.baseAddress, $0.count)
                }
                guard count >= 0 else { throw V1StoreSnapshotError.unsafeEntry(relativePath) }
                if count == 0 { break }
                byteCount += Int64(count)
                hasher.update(data: Data(buffer.prefix(count)))
            }
            return (
                byteCount,
                hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }
    }

    fileprivate static func readFile(relativePath: String, rootDescriptor: Int32) throws -> Data {
        try withFileDescriptor(relativePath: relativePath, rootDescriptor: rootDescriptor) { file in
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(file, $0.baseAddress, $0.count)
                }
                guard count >= 0 else { throw V1StoreSnapshotError.unsafeEntry(relativePath) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }
    }

    private static func withFileDescriptor<T>(
        relativePath: String,
        rootDescriptor: Int32,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw V1StoreSnapshotError.unsafeEntry(relativePath)
        }

        var descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else { throw V1StoreSnapshotError.unsafeEntry(relativePath) }
        defer { Darwin.close(descriptor) }

        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                if errno == ELOOP { throw V1StoreSnapshotError.symbolicLink(relativePath) }
                throw V1StoreSnapshotError.unsafeEntry(relativePath)
            }
            Darwin.close(descriptor)
            descriptor = next
        }

        let file = components.last!.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard file >= 0 else {
            if errno == ELOOP { throw V1StoreSnapshotError.symbolicLink(relativePath) }
            throw V1StoreSnapshotError.unsafeEntry(relativePath)
        }
        defer { Darwin.close(file) }
        var status = stat()
        guard Darwin.fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw V1StoreSnapshotError.unsafeEntry(relativePath)
        }
        return try body(file)
    }
}

public struct V1StoreSnapshot: Sendable {
    public let directory: URL
    public let databaseURL: URL
    public let auxiliaryDirectory: URL
    public let sourceManifest: V1SourceManifest

    public func remove(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }
}

public enum V1StoreSnapshotter {
    public static func snapshotReadOnly(
        sourceDirectory: URL
    ) async throws -> V1StoreSnapshot {
        try await snapshotReadOnly(sourceDirectory: sourceDirectory, beforeFinalManifest: {})
    }

    static func snapshotReadOnly(
        sourceDirectory: URL,
        beforeFinalManifest: @Sendable () throws -> Void
    ) async throws -> V1StoreSnapshot {
        let source = sourceDirectory.standardizedFileURL
        let before = try V1SourceManifest.capture(directory: source)
        guard before.entries.contains(where: { $0.relativePath == "astrotool.sqlite" }) else {
            throw V1StoreSnapshotError.missingDatabase
        }

        let snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-V1-Snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        let auxiliaryDirectory = snapshotDirectory.appendingPathComponent("auxiliary", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: auxiliaryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let snapshotDatabase = snapshotDirectory.appendingPathComponent("astrotool.sqlite")
            do {
                let sourceDatabase = try SQLiteDB(
                    readOnlyPath: source.appendingPathComponent("astrotool.sqlite").path
                )
                try sourceDatabase.backup(to: snapshotDatabase)
            }

            let rootDescriptor = Darwin.open(
                source.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rootDescriptor >= 0 else {
                throw V1StoreSnapshotError.invalidSourceDirectory
            }
            defer { Darwin.close(rootDescriptor) }

            for entry in before.entries where shouldCopyAuxiliary(entry.relativePath) {
                let data = try V1SourceManifest.readFile(
                    relativePath: entry.relativePath,
                    rootDescriptor: rootDescriptor
                )
                let destination = auxiliaryDirectory.appendingPathComponent(entry.relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try data.write(to: destination, options: .withoutOverwriting)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o400],
                    ofItemAtPath: destination.path
                )
            }

            try beforeFinalManifest()
            guard try V1SourceManifest.capture(directory: source) == before else {
                throw V1StoreSnapshotError.sourceChanged
            }
            return V1StoreSnapshot(
                directory: snapshotDirectory,
                databaseURL: snapshotDatabase,
                auxiliaryDirectory: auxiliaryDirectory,
                sourceManifest: before
            )
        } catch {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw error
        }
    }

    private static func shouldCopyAuxiliary(_ relativePath: String) -> Bool {
        if relativePath == "config.json" { return true }
        let components = relativePath.split(separator: "/")
        guard let first = components.first else { return false }
        switch first {
        case "notes":
            return true
        case "conversions", "cleanup_quarantine", "mutation-journal":
            return relativePath.hasSuffix(".json")
        default:
            return false
        }
    }
}
