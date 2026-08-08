import Foundation

public struct QuarantineState: Codable, Equatable, Sendable {
    public let fileCount: Int
    public let batchCount: Int
    public let totalBytes: Int64
    public let oldestBatch: Date?

    public init(fileCount: Int, batchCount: Int, totalBytes: Int64, oldestBatch: Date?) {
        self.fileCount = fileCount
        self.batchCount = batchCount
        self.totalBytes = totalBytes
        self.oldestBatch = oldestBatch
    }
}

/// Read-only aggregation of `.astro_tool/cleanup_quarantine`. Any traversal
/// error is surfaced instead of returning a misleading empty/clean state.
public enum QuarantineSummary {
    public static func inspect(root: URL, config _: AstroConfig) throws -> QuarantineState {
        let directory = root.appendingPathComponent(
            ".astro_tool/cleanup_quarantine", isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return QuarantineState(fileCount: 0, batchCount: 0, totalBytes: 0, oldestBatch: nil)
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        let batchDirectories = try children.filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        let oldestBatch = batchDirectories.compactMap {
            batchFormatter.date(from: $0.lastPathComponent)
        }.min()

        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            // Hidden residue (especially `.DS_Store`) is a primary cleanup
            // input, so it must count toward quarantine size and file totals.
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw AstroError.accessDenied(path: directory.path)
        }

        var fileCount = 0
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            totalBytes += Int64(values.fileSize ?? 0)
        }
        if let traversalError { throw traversalError }

        return QuarantineState(
            fileCount: fileCount,
            batchCount: batchDirectories.count,
            totalBytes: totalBytes,
            oldestBatch: oldestBatch
        )
    }

    private static let batchFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
