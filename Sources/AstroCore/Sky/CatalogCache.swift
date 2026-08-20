import Foundation

/// A snapshot of every extended-catalog target `CatalogFetcher` last
/// downloaded, persisted so Planning's rendering path never makes a network
/// call of its own -- fetch once (via the opt-in "Update Catalog" action),
/// then work offline. `version` is bumped whenever this shape changes
/// incompatibly; `CatalogCache.load()` treats any mismatch exactly like a
/// corrupt file (falls back to nil, never partially decodes).
public struct CatalogCachePayload: Codable, Sendable, Equatable {
    public let version: Int
    public let fetchedAt: Date
    public let targets: [CatalogTarget]

    public init(version: Int = CatalogCache.currentVersion, fetchedAt: Date, targets: [CatalogTarget]) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.targets = targets
    }
}

public enum CatalogCacheError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
}

/// Reads/writes the extended-catalog cache under Application Support,
/// deliberately OUTSIDE any image library and outside the per-library
/// `Libraries/<id>` tree `AppStoragePaths` (`AstroApplication`) uses -- this
/// data isn't library-scoped, it's the same regardless of which library is
/// open, so it lives in its own top-level `Catalog` directory instead.
///
/// `load()` never throws: a missing file, unreadable/corrupt JSON, and a
/// version mismatch all just mean "no cached extension yet", so every
/// caller's fallback is the same one line -- keep using
/// `TargetCatalog.all` (constraint 4 of the wave-5 plan's Task 5: "a
/// corrupt cache falls back to the built-in catalog instead of failing").
public struct CatalogCache: Sendable {
    public static let currentVersion = 1

    public let fileURL: URL

    /// `FileManager` is intentionally never stored (it isn't `Sendable`) --
    /// every method below takes it as a parameter instead, same shape
    /// `AppStoragePaths.production(fileManager:)` (`AstroApplication`) uses.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/AstroTool/Catalog/extended-catalog-v<version>.json`.
    public static func productionFileURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CatalogCacheError.applicationSupportUnavailable
        }
        return applicationSupport
            .appendingPathComponent("AstroTool", isDirectory: true)
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("extended-catalog-v\(currentVersion).json")
    }

    public func save(_ payload: CatalogCachePayload, fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(payload)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Never throws -- see the type's own doc comment for why every failure
    /// mode here (missing file, corrupt JSON, version mismatch) resolves to
    /// `nil` rather than propagating an error.
    public func load() -> CatalogCachePayload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let payload = try? Self.decoder.decode(CatalogCachePayload.self, from: data) else { return nil }
        guard payload.version == Self.currentVersion else { return nil }
        return payload
    }

    public func clear(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
