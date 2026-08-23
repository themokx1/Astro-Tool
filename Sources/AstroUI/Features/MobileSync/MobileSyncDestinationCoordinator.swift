import Foundation

/// The file exporter writes a tiny, app-owned placeholder directory while
/// the person chooses a destination. Only that exact marker is removed
/// before the package service performs its exclusive publication.
public enum MobileSyncDestinationCoordinator {
    public static func placeholderName(for token: String) -> String {
        ".astrotool-package-placeholder-\(token)"
    }

    public static func removePlaceholder(at destination: URL, token: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destination.path) else { return }
        let entries = try fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        guard entries.count == 1, entries[0].lastPathComponent == placeholderName(for: token) else { return }
        try fileManager.removeItem(at: destination)
    }
}
