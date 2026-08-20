import AstroApplication
import AstroCore
@testable import AstroUI
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

// MARK: - Local fixture builders
//
// Mirrors this codebase's own established convention (see
// `CalibrationStoreTests.swift`'s `calibStoreCard`/`calibStoreHeaderData`)
// of duplicating a tiny fixture builder per test file rather than sharing
// one across test TARGETS -- `Tests/AstroCoreTests/FITSTestBuilder.swift`/
// `ImageTestBuilder.swift` live in a different module (`AstroCoreTests`)
// this file (`AstroUITests`) cannot import.

private func captureImportStoreCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func captureImportStoreHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(captureImportStoreCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// Writes a minimal FITS file with an `IMAGETYP` and `DATE-OBS` card --
/// enough for `CaptureImportScanner.classify`'s FITS path to propose a role
/// and a capture instant, which is all `CaptureBurstGrouper`/
/// `CaptureImportStore` need for these tests.
private func writeFITSFixture(to url: URL, imagetyp: String, dateObs: String) throws {
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    0",
        "IMAGETYP= '\(imagetyp)'",
        "DATE-OBS= '\(dateObs)'",
        "END",
    ]
    try captureImportStoreHeaderData(cards).write(to: url)
}

/// Writes a valid TIFF (named with whatever extension `url` carries -- a
/// `.cr3` name exercises the exact same ImageIO/Exif codepath a real CR3
/// would, see `ImageMetaReader`'s own doc comment on why a genuine CR3
/// fixture can't be built in a test) with an Exif `DateTimeOriginal` and
/// `ExposureTime` -- what `CaptureImportScanner`'s raw-file path reads for
/// `captureInstant`/`exposureSeconds`.
private func writeRawFixture(to url: URL, dateTimeOriginal: String, exposureSeconds: Double) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ), let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
    else {
        Issue.record("failed to build the raw test fixture at \(url.path)")
        return
    }
    let exifDict: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal,
        kCGImagePropertyExifExposureTime: exposureSeconds,
    ]
    let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: exifDict]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

private func makeTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Tests

@Suite("CaptureImportStore group classify")
@MainActor
struct CaptureImportStoreTests {
    private func waitUntilCondition(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeStore() throws -> (store: CaptureImportStore, rootURL: URL) {
        let rootURL = try makeTempDir("capture-import-store-root")
        let store = CaptureImportStore(
            rootURL: rootURL, accessMode: .mutationEnabled, indexedFolders: [], existingProjects: [], mountedVolumes: []
        )
        return (store, rootURL)
    }

    @Test("Scanning a source with two separate bursts produces two groups, each already resolved from its FITS IMAGETYP")
    func scanProducesGroupsResolvedFromFits() async throws {
        let (store, rootURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let source = try makeTempDir("capture-import-store-source")
        defer { try? FileManager.default.removeItem(at: source) }

        for index in 0..<4 {
            try writeFITSFixture(
                to: source.appendingPathComponent("light_\(index).fits"),
                imagetyp: "Light Frame", dateObs: "2026-08-16T21:00:0\(index)"
            )
        }
        for index in 0..<4 {
            try writeFITSFixture(
                to: source.appendingPathComponent("flat_\(index).fits"),
                imagetyp: "Flat Field", dateObs: "2026-08-17T02:00:0\(index)"
            )
        }

        store.chooseSource(source)
        try await waitUntilCondition { store.step == .classify }

        #expect(store.groups.count == 2)
        let lightGroup = try #require(store.groups.first { $0.files.contains { $0.fileName.hasPrefix("light_") } })
        let flatGroup = try #require(store.groups.first { $0.files.contains { $0.fileName.hasPrefix("flat_") } })
        #expect(lightGroup.fileCount == 4)
        #expect(flatGroup.fileCount == 4)
        // Already resolved -- no override needed -- because every file in
        // each group proposed the same FITS IMAGETYP role.
        #expect(store.resolvedRole(for: lightGroup) == .light)
        #expect(store.resolvedRole(for: flatGroup) == .flat)
        #expect(store.canProceedPastClassify)
    }

    @Test("fileIDs(forSelectedRows:) expands a group row to every one of its files, and passes a file row through unchanged")
    func fileIDsForSelectedRowsExpandsGroupsAndPassesFilesThrough() async throws {
        let (store, rootURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let source = try makeTempDir("capture-import-store-source")
        defer { try? FileManager.default.removeItem(at: source) }

        for index in 0..<3 {
            try writeFITSFixture(
                to: source.appendingPathComponent("dark_\(index).fits"),
                imagetyp: "Dark Frame", dateObs: "2026-08-16T23:00:0\(index)"
            )
        }
        store.chooseSource(source)
        try await waitUntilCondition { store.step == .classify }
        let group = try #require(store.groups.first)

        let expandedFromGroup = store.fileIDs(forSelectedRows: [CaptureImportStore.groupRowID(group.id)])
        #expect(expandedFromGroup == group.fileIDs)

        let oneFile = try #require(group.files.first)
        let expandedFromFile = store.fileIDs(forSelectedRows: [CaptureImportStore.fileRowID(oneFile.id)])
        #expect(expandedFromFile == [oneFile.id])
    }

    @Test("Assigning a role to a group applies it to every file the group expands to in resolvedItems -- the command's per-file input")
    func assigningRoleToAGroupAppliesToEveryFileInResolvedItems() async throws {
        let (store, rootURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let source = try makeTempDir("capture-import-store-source")
        defer { try? FileManager.default.removeItem(at: source) }

        // CR3 files never propose a role on their own (no IMAGETYP
        // equivalent) -- exactly the "every row Besorolatlan" case the
        // owner's screenshot showed, and exactly the case a group-level
        // role assignment needs to resolve.
        for index in 0..<5 {
            try writeRawFixture(
                to: source.appendingPathComponent("IMG_000\(index).cr3"),
                dateTimeOriginal: "2026:08:16 21:3\(index):00", exposureSeconds: 300
            )
        }
        store.chooseSource(source)
        try await waitUntilCondition { store.step == .classify }
        let group = try #require(store.groups.first)
        #expect(group.fileCount == 5)
        #expect(store.resolvedRole(for: group) == nil, "an all-CR3 group never auto-resolves")

        store.assignRole(.dark, toGroups: [group.id])

        #expect(store.resolvedRole(for: group) == .dark)
        let items = store.resolvedItems
        #expect(items.count == 5)
        #expect(items.allSatisfy { $0.role == .dark })
        #expect(Set(items.map(\.relativeSourcePath)) == Set(group.files.map(\.relativeSourcePath)))
        #expect(store.canProceedPastClassify)
    }

    @Test("Excluding a group's row id excludes every file in it")
    func excludingAGroupRowExcludesEveryFile() async throws {
        let (store, rootURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let source = try makeTempDir("capture-import-store-source")
        defer { try? FileManager.default.removeItem(at: source) }

        for index in 0..<3 {
            try writeRawFixture(
                to: source.appendingPathComponent("IMG_000\(index).cr3"),
                dateTimeOriginal: "2026:08:16 21:0\(index):00", exposureSeconds: 0.0002
            )
        }
        store.chooseSource(source)
        try await waitUntilCondition { store.step == .classify }
        let group = try #require(store.groups.first)

        store.exclude(store.fileIDs(forSelectedRows: [CaptureImportStore.groupRowID(group.id)]))

        #expect(store.isGroupFullyExcluded(group))
        #expect(store.activeFiles(in: group).isEmpty)
        #expect(store.resolvedItems.isEmpty)
        // Nothing left unresolved -- everything in the (only) group was
        // excluded, not silently carried forward.
        #expect(store.canProceedPastClassify == false, "an empty active-file set never counts as proceedable")
    }

    @Test("A sub-millisecond CR3 group suggests bias until resolved, then stops suggesting")
    func subMillisecondGroupSuggestsBiasUntilResolved() async throws {
        let (store, rootURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let source = try makeTempDir("capture-import-store-source")
        defer { try? FileManager.default.removeItem(at: source) }

        for index in 0..<4 {
            try writeRawFixture(
                to: source.appendingPathComponent("IMG_000\(index).cr3"),
                dateTimeOriginal: "2026:08:16 21:0\(index):00", exposureSeconds: 0.0002
            )
        }
        store.chooseSource(source)
        try await waitUntilCondition { store.step == .classify }
        let group = try #require(store.groups.first)

        #expect(store.suggestedRole(for: group) == .bias)

        store.assignRole(.bias, toGroups: [group.id])

        #expect(store.suggestedRole(for: group) == nil, "a resolved group has nothing left to suggest")
    }
}
