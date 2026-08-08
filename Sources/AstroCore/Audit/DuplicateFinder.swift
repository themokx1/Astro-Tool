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
    /// is never re-read.
    ///
    /// Real astro libraries have thousands of same-camera frames that are
    /// all byte-identical in *size* (same sensor, same bit depth, same
    /// dimensions every exposure), so the size prefilter alone lets nearly
    /// everything through to hashing. To avoid full-hashing hundreds of GB
    /// of frames that merely share a size, uncached same-size files are
    /// first grouped by a cheap prefix hash (first 64 KiB, streamed) — only
    /// files whose (size, prefix) *both* collide go on to full-content
    /// SHA-256. Prefix hashes are a pure in-run optimization and are never
    /// persisted; only full hashes are written back to `content_hash`, same
    /// as before. Both tiers stream in bounded chunks inside an
    /// `autoreleasepool` per chunk, so peak memory stays flat regardless of
    /// file count or size — never loading a whole frame into memory.
    public static func findDuplicates(
        db: Database,
        config: AstroConfig,
        minSizeBytes: Int64 = 1_048_576,
        onPrefixHash: (() -> Void)? = nil,
        onFullHash: (() -> Void)? = nil
    ) throws -> [Finding] {
        let files = try db.allFiles(includeMissing: false)
        let candidates = files.filter { $0.size >= minSizeBytes }

        var bySize: [Int64: [FileRecord]] = [:]
        for file in candidates {
            bySize[file.size, default: []].append(file)
        }

        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)

        var byHash: [String: [FileRecord]] = [:]

        func fullHashAndStore(_ file: FileRecord) throws -> String {
            let fileURL = root.appendingPathComponent(file.path)
            let hash = try sha256Hash(of: fileURL)
            onFullHash?()
            var updated = file
            updated.contentHash = hash
            try db.upsertFile(updated)
            byHash[hash, default: []].append(updated)
            return hash
        }

        for (_, group) in bySize where group.count >= 2 {
            var uncachedFiles: [FileRecord] = []
            for file in group {
                if let cached = file.contentHash {
                    byHash[cached, default: []].append(file)
                } else {
                    uncachedFiles.append(file)
                }
            }
            guard !uncachedFiles.isEmpty else { continue }

            // The prefix-hash tier only applies when this whole bucket is
            // uncached (nothing else to compare against) and there's more
            // than one uncached file to discriminate between. If any
            // sibling in the bucket already has a cached full hash, an
            // uncached file might duplicate *that* sibling's content, and a
            // prefix hash can't be compared against a full hash we already
            // have (re-reading the cached file for its prefix would defeat
            // the point of caching) -- so fall straight back to full
            // hashing every uncached file, same as before the prefix tier
            // existed. This fallback only matters on repeat runs with a
            // handful of new files mixed into an already-hashed bucket --
            // the expensive first-run case (nothing cached yet) always
            // takes the prefix-hash tier below.
            let bucketIsAllUncached = uncachedFiles.count == group.count
            guard bucketIsAllUncached, uncachedFiles.count >= 2 else {
                for file in uncachedFiles {
                    _ = try fullHashAndStore(file)
                }
                continue
            }

            var byPrefix: [String: [FileRecord]] = [:]
            for file in uncachedFiles {
                let fileURL = root.appendingPathComponent(file.path)
                let prefix = try prefixHash(of: fileURL)
                onPrefixHash?()
                byPrefix[prefix, default: []].append(file)
            }

            for (_, prefixGroup) in byPrefix where prefixGroup.count >= 2 {
                for file in prefixGroup {
                    _ = try fullHashAndStore(file)
                }
            }
            // prefixGroup.count == 1 subgroups are intentionally left
            // unhashed: no other same-size file shares this file's first
            // 64 KiB, so it cannot be a full-content duplicate of anything
            // else in this bucket.
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

        let message = "azonos tartalom \(sortedPaths.count) fájlban (méret: \(size) bájt/fájl, "
            + "pazarolt hely: \(wastedBytes) bájt): \(sortedPaths.joined(separator: ", "))"

        // sessions/ is the canonical RAW area -- never propose touching a
        // copy that lives there, only copies outside it.
        let removalCandidates = sortedPaths.filter { !isUnderSessions($0) }

        // The note deliberately never names a sessions/ path, even as "the
        // one to keep" -- it must read safely on its own without pointing
        // at anything under the canonical RAW area.
        let note: String
        if removalCandidates.isEmpty {
            note = "minden másolat a sessions/ alatt van (a kanonikus RAW terület) — kézzel ellenőrizd, mielőtt bármit törölnél"
        } else {
            note = "deduplikálásra javasolt (redundáns másolatok a sessions/ területen kívül): "
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

    /// First-64-KiB prefix hash of `url`, read in a single bounded read
    /// inside an `autoreleasepool`. Cheap second discriminator applied to
    /// same-size files before paying for a full-content SHA-256: two files
    /// that merely share a size (e.g. same-camera FITS frames) almost
    /// always differ within their first 64 KiB (FITS headers alone carry
    /// per-frame timestamps), so this tier filters out nearly all
    /// non-duplicates without reading the rest of the file. Purely an
    /// in-run optimization -- never persisted to `content_hash`.
    private static let prefixSampleBytes = 65536

    private static func prefixHash(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw AstroError.pathNotFound(path: url.path)
        }
        defer { try? handle.close() }

        let digest = try autoreleasepool { () -> SHA256.Digest in
            let chunk = try handle.read(upToCount: prefixSampleBytes) ?? Data()
            var hasher = SHA256()
            hasher.update(data: chunk)
            return hasher.finalize()
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Streams `url` in 1 MiB chunks through SHA-256 so hashing a
    /// multi-gigabyte FITS frame never loads the whole file into memory.
    /// Each chunk's read + hash update happens inside its own
    /// `autoreleasepool`: without it, the autoreleased buffers backing
    /// every chunk linger for the entire audit run instead of being freed
    /// as they're consumed, so peak memory grows with total bytes hashed
    /// across *all* files instead of staying bounded to one chunk.
    ///
    /// Not `private` (R11-T14): `FixityVerifier` re-hashes the exact same
    /// way to compare against a cached hash, and re-implementing the same
    /// chunked/autoreleasepool'd streaming logic there would just be a
    /// second copy to keep in sync.
    static func sha256Hash(of url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw AstroError.pathNotFound(path: url.path)
        }
        defer { try? handle.close() }

        let chunkSize = 1_048_576
        var hasher = SHA256()
        while true {
            let isDone = try autoreleasepool { () -> Bool in
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                guard !chunk.isEmpty else { return true }
                hasher.update(data: chunk)
                return false
            }
            if isDone { break }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
