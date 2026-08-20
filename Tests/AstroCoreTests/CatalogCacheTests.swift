import Foundation
import Testing
@testable import AstroCore

@Suite("CatalogCache persists, versions, and falls back on corruption")
struct CatalogCacheTests {
    private func makeTempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroTool-CatalogCacheTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("extended-catalog-v1.json")
    }

    @Test("Saving then loading round-trips the payload exactly")
    func saveThenLoadRoundTrips() throws {
        let url = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = CatalogCache(fileURL: url)

        let target = CatalogTarget(
            designation: "LBN 437", commonNameHU: nil, raDeg: 338.051, decDeg: 40.591,
            kind: .other, sizeArcmin: 75, magnitude: nil
        )
        let payload = CatalogCachePayload(fetchedAt: Date(timeIntervalSince1970: 1_755_000_000), targets: [target])

        try cache.save(payload)
        let loaded = try #require(cache.load())

        #expect(loaded.version == CatalogCache.currentVersion)
        #expect(loaded.targets == [target])
        #expect(loaded.fetchedAt == payload.fetchedAt)
    }

    @Test("Loading before any save returns nil, not an error")
    func loadBeforeSaveReturnsNil() {
        let cache = CatalogCache(fileURL: makeTempCacheURL())
        #expect(cache.load() == nil)
    }

    @Test("A corrupt cache file falls back to nil instead of throwing")
    func corruptCacheFallsBack() throws {
        let url = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ this is not valid JSON at all".utf8).write(to: url)

        let cache = CatalogCache(fileURL: url)
        #expect(cache.load() == nil)
    }

    @Test("A version mismatch falls back to nil instead of misinterpreting an old shape")
    func versionMismatchFallsBack() throws {
        let url = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = CatalogCache(fileURL: url)
        let target = CatalogTarget(
            designation: "Sh2-1", commonNameHU: nil, raDeg: 1, decDeg: 1,
            kind: .emissionNebula, sizeArcmin: nil, magnitude: nil
        )
        let futurePayload = CatalogCachePayload(version: CatalogCache.currentVersion + 1, fetchedAt: Date(), targets: [target])
        try cache.save(futurePayload)

        #expect(cache.load() == nil)
    }

    @Test("clear() removes an existing cache file and is a no-op when nothing is cached")
    func clearRemovesFile() throws {
        let url = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = CatalogCache(fileURL: url)
        try cache.save(CatalogCachePayload(fetchedAt: Date(), targets: []))
        #expect(FileManager.default.fileExists(atPath: url.path))

        try cache.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(cache.load() == nil)

        // Clearing again (nothing left to clear) must not throw.
        try cache.clear()
    }

    @Test("Production file URL lives outside any image library, under Application Support/AstroTool/Catalog")
    func productionFileURLIsOutsideLibraryTree() throws {
        let url = try CatalogCache.productionFileURL()
        #expect(url.pathComponents.contains("AstroTool"))
        #expect(url.pathComponents.contains("Catalog"))
        #expect(!url.pathComponents.contains("Libraries"), "extended catalog cache must not live under the per-library Libraries/<id> tree")
        #expect(url.lastPathComponent == "extended-catalog-v\(CatalogCache.currentVersion).json")
    }
}
