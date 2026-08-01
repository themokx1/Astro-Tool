import CryptoKit
import Foundation

/// Hash-based duplicate-content detector. Unlike the `AuditRule` family this
/// isn't a pure function of a read-only snapshot: it needs write access to
/// `Database` to persist the SHA-256 hashes it computes, so the cache
/// survives across runs instead of re-reading gigabytes of FITS data every
/// time. That write-back need is exactly why this stays a standalone
/// function taking `db` directly rather than conforming to `AuditRule` (see
/// `AuditContext`, which is deliberately read-only).
public enum DuplicateFinder {
    /// Groups tracked, non-missing files by exact size, then — for
    /// same-size groups only — by SHA-256 content hash, and returns one
    /// `Finding` per group of two or more files sharing a hash.
    ///
    /// Files smaller than `minSizeBytes` are skipped entirely (duplicate
    /// tiny files, e.g. empty placeholder frames, aren't worth flagging).
    /// A file's `contentHash` is read from the DB cache when present — the
    /// scanner already resets it to `nil` whenever a file is added or its
    /// content changes, so a non-nil cached hash is trustworthy and the file
    /// is never re-read. Cache misses are hashed by streaming the file in
    /// 1 MiB chunks (never loading a whole frame into memory) and the
    /// result is written straight back to the file's DB record.
    public static func findDuplicates(
        db: Database,
        config: AstroConfig,
        minSizeBytes: Int64 = 1_048_576
    ) throws -> [Finding] {
        let files = try db.allFiles(includeMissing: false)
        let candidates = files.filter { $0.size >= minSizeBytes }

        var bySize: [Int64: [FileRecord]] = [:]
        for file in candidates {
            bySize[file.size, default: []].append(file)
        }

        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)

        var byHash: [String: [FileRecord]] = [:]
        for (_, group) in bySize where group.count >= 2 {
            for var file in group {
                let hash: String
                if let cached = file.contentHash {
                    hash = cached
                } else {
                    let fileURL = root.appendingPathComponent(file.path)
                    hash = try sha256Hash(of: fileURL)
                    file.contentHash = hash
                    try db.upsertFile(file)
                }
                byHash[hash, default: []].append(file)
            }
        }

        var findings: [Finding] = []
        for (_, group) in byHash where group.count >= 2 {
            findings.append(finding(for: group))
        }

        return findings.sorted { $0.path < $1.path }
    }

    // MARK: - Finding construction

    private static func finding(for group: [FileRecord]) -> Finding {
        let sortedPaths = group.map(\.path).sorted()
        let firstPath = sortedPaths[0]
        let size = group.first?.size ?? 0
        let wastedBytes = size * Int64(sortedPaths.count - 1)

        let message = "duplicate content across \(sortedPaths.count) files (size \(size) bytes each, "
            + "wasted \(wastedBytes) bytes): \(sortedPaths.joined(separator: ", "))"

        // sessions/ is the canonical RAW area -- never propose touching a
        // copy that lives there, only copies outside it.
        let removalCandidates = sortedPaths.filter { !isUnderSessions($0) }

        // The note deliberately never names a sessions/ path, even as "the
        // one to keep" -- it must read safely on its own without pointing
        // at anything under the canonical RAW area.
        let note: String
        if removalCandidates.isEmpty {
            note = "all copies are under sessions/ (the canonical RAW area) -- review manually before removing anything"
        } else {
            note = "candidates to deduplicate (redundant copies outside sessions/): "
                + removalCandidates.joined(separator: ", ")
        }

        return Finding(
            severity: .suspicious,
            category: "duplicate-content",
            path: firstPath,
            message: message,
            suggestion: .review(note: note)
        )
    }

    private static func isUnderSessions(_ path: String) -> Bool {
        path == "sessions" || path.hasPrefix("sessions/")
    }

    // MARK: - Hashing

    /// Streams `url` in 1 MiB chunks through SHA-256 so hashing a
    /// multi-gigabyte FITS frame never loads the whole file into memory.
    private static func sha256Hash(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw AstroError.pathNotFound(path: url.path)
        }
        defer { try? handle.close() }

        let chunkSize = 1_048_576
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
