import CryptoKit
import Foundation
import Testing
@testable import AstroApplication
@testable import AstroMobileDomain
@testable import AstroMobileTransport

/// A deterministic, end-to-end smoke gate for the mobile package round trip
/// (Wave 1 Task 8, step 3). Unlike the narrower unit suites, this drives the
/// *real* production surfaces the shipping app uses:
///
/// - `PortableLibraryIdentityStore`, `AppStoragePaths.production`,
///   `MetadataStore`, and `NightBriefingRevisionStore` build a real fixture
///   library on disk (project + annotation, briefing + checklist).
/// - `MobileSnapshotComposer` (the same adapter
///   `MobileReturnApplicationCoordinator`'s own production snapshot provider
///   uses) turns those typed domain records into a `MobileLibrarySnapshot`.
/// - `MobileReturnApplicationCoordinator(rootURL:)` -- the fully public
///   initializer, not the package-internal `.production(...)` test factory
///   -- performs the forward publish and, later, the return-changes preview
///   and apply. Its internal snapshot provider is the literal one shipped in
///   `MobileReturnApplicationCoordinator.swift`.
/// - `MobilePackageService` plays the phone's role for both directions:
///   authenticating/decrypting the forward package and encrypting the
///   return package, exactly as `MobileSyncStoreTests` does.
///
/// The one duplication this suite cannot avoid: `publishForwardSnapshot`
/// takes an already-composed snapshot, and the coordinator's matching
/// composition closure is `private`. This suite rebuilds that same
/// composition from the identical real stores/composer
/// (mirroring `MobileSyncStore.metadataSnapshotProvider`) purely to obtain a
/// snapshot value to publish; the return-side preview/apply always goes
/// through the coordinator's own real, unduplicated internal provider.
@Suite("Mobile package smoke: end-to-end round trip")
struct MobilePackageSmokeTests {
    @Test("forward publish, phone import, return apply, and fixture-file safety")
    func endToEndRoundTripLeavesLibraryFilesUntouched() async throws {
        let fixture = try MobileSmokeFixture.make()
        defer { fixture.cleanUp() }
        let root = fixture.root
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // --- 1. Real domain records: one project with an annotation, one
        // briefing revision with a checklist. ---
        let identityStore = PortableLibraryIdentityStore()
        let identityPreview = try identityStore.preview(root: root)
        let libraryID = try identityStore.loadOrCreate(root: root, confirmedID: identityPreview.proposedID)

        let paths = try AppStoragePaths.production(
            libraryID: LibraryIdentity(rootURL: root),
            libraryRoot: root
        )
        let metadataStore = try MetadataStore(storagePaths: paths)
        let project = ProjectRecord(id: UUID(), catalogID: "M42", displayName: "Orion Nebula", phase: .collecting)
        try await metadataStore.save(project)
        try await metadataStore.createProjectAnnotation(.init(
            projectID: project.id,
            integrationGoalHours: 8,
            notes: "Initial field note",
            updatedAt: now
        ))
        let annotation = try #require(await metadataStore.projectAnnotation(projectID: project.id))

        let briefingStore = NightBriefingRevisionStore(directory: paths.briefings)
        let briefingID = UUID()
        let originalBriefing = try await briefingStore.create(NightBriefingDraft(
            id: briefingID,
            savedAt: now,
            checklist: [BriefingChecklistSection(
                id: "setup",
                title: "Setup",
                items: [BriefingChecklistItem(id: "focus", title: "Focus")]
            )],
            notes: "Mac briefing note"
        ))

        // --- 2. Manifest of the fixture, captured before any part of the
        // mobile flow runs. ---
        let manifestBefore = try captureManifest(of: root)
        #expect(fixture.decoyRelativePaths.allSatisfy { manifestBefore[$0] != nil })

        // --- 3. Forward export through the real coordinator, "phone-side"
        // authenticate + commit through MobilePackageService. ---
        let revisionStore = MobileSnapshotRevisionStore(
            fileURL: root.appendingPathComponent(".astro-tool/mobile-snapshot-revision.json")
        )
        let revision = try await revisionStore.next()
        let baseSnapshot = try MobileSnapshotComposer().compose(
            input: .init(
                libraryID: libraryID,
                revision: revision,
                projects: [project],
                nights: [],
                captures: [],
                annotations: [annotation],
                briefings: [originalBriefing],
                integrationSecondsByCaptureID: [:]
            ),
            now: now
        )

        let coordinator = try MobileReturnApplicationCoordinator(rootURL: root)
        let forwardKey = OneTimePackageKey()
        let forwardURL = root.appendingPathComponent("exchange/forward.astromobile", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("exchange", isDirectory: true), withIntermediateDirectories: true)
        let publication = try await coordinator.publishForwardSnapshot(baseSnapshot, to: forwardURL, wrapping: forwardKey)
        #expect(publication.encryptedByteCount > 0)

        let phoneImportService = MobilePackageService()
        let phoneAuthenticated = try await phoneImportService.authenticatePreview(from: forwardURL, wrapping: forwardKey)
        #expect(phoneAuthenticated.preview.snapshotSummary.projectCount == 1)
        #expect(phoneAuthenticated.preview.snapshotSummary.briefingCount == 1)
        #expect(phoneAuthenticated.preview.snapshotSummary.noteCount == 2)
        let importedEnvelope = try await phoneImportService.commitImport(token: phoneAuthenticated.token)
        let importedSnapshot = try #require(importedEnvelope.snapshot)
        #expect(importedSnapshot.projects.first?.catalogID == "M42")
        #expect(importedSnapshot.projects.first?.displayName == "Orion Nebula")
        #expect(importedSnapshot.notes.contains { $0.scope == .project && $0.text == "Initial field note" })
        #expect(importedSnapshot.notes.contains { $0.scope == .briefing && $0.text == "Mac briefing note" })
        let importedChecklistItem = try #require(importedSnapshot.briefings.first?.checklist.first?.items.first)
        #expect(importedChecklistItem.id == "focus")
        let importedProjectNote = try #require(importedSnapshot.notes.first { $0.scope == .project })
        let importedBriefingID = try #require(importedSnapshot.briefings.first?.id)

        let decryptedForwardEnvelopeText = String(decoding: try MobileJSON.encoder.encode(importedEnvelope), as: UTF8.self)
        for forbidden in fixture.forbiddenStrings {
            #expect(!decryptedForwardEnvelopeText.localizedCaseInsensitiveContains(forbidden), "decrypted forward envelope leaked \(forbidden)")
        }

        // --- 4. Exactly one checklist completion + one note revision,
        // based on the imported snapshot's own base revisions. ---
        let deviceID = UUID()
        let checklistChangeID = UUID()
        let noteChangeID = UUID()
        let checklistChange = MobileChange.checklistCompletion(.init(
            changeID: checklistChangeID,
            deviceID: deviceID,
            briefingID: importedBriefingID,
            itemID: importedChecklistItem.id,
            baseRevision: importedChecklistItem.baseRevision,
            isCompleted: true,
            createdAt: now.addingTimeInterval(1)
        ))
        let noteChange = MobileChange.noteRevision(.init(
            changeID: noteChangeID,
            deviceID: deviceID,
            noteID: importedProjectNote.id,
            ownerID: importedProjectNote.ownerID,
            baseRevision: importedProjectNote.baseRevision,
            text: "Phone annotation update",
            createdAt: now.addingTimeInterval(1)
        ))

        // --- 5. Encrypted return package, applied through the PUBLIC
        // MobileReturnApplicationCoordinator. ---
        let returnKey = OneTimePackageKey()
        let returnURL = root.appendingPathComponent("exchange/return.astromobile", isDirectory: true)
        let phoneReturnService = MobilePackageService()
        _ = try await phoneReturnService.export(
            MobilePackageEnvelope(
                purpose: .returnChanges,
                snapshot: baseSnapshot,
                baseSnapshotID: baseSnapshot.snapshotID,
                changes: [checklistChange, noteChange],
                acknowledgedChangeIDs: []
            ),
            to: returnURL,
            wrapping: returnKey
        )

        let review = try await coordinator.preview(from: returnURL, wrapping: returnKey)
        #expect(review.changePreview.conflicts.isEmpty)
        #expect(review.changePreview.rejected.isEmpty)
        #expect(review.changePreview.duplicates.isEmpty)
        let receipt = try await coordinator.apply(review, resolutions: [:], confirmed: true)
        #expect(Set(receipt.appliedChangeIDs) == Set([checklistChangeID, noteChangeID]))

        let updatedBriefing = try #require(await briefingStore.latest(id: briefingID))
        #expect(updatedBriefing.checklist.first?.items.first?.isCompleted == true)
        #expect(updatedBriefing.mobileChangeIDs.contains(checklistChangeID))
        let updatedAnnotation = try #require(await metadataStore.projectAnnotation(projectID: project.id))
        #expect(updatedAnnotation.notes == "Phone annotation update")
        #expect(updatedAnnotation.mobileChangeIDs.contains(noteChangeID))

        // --- 6. The fixture's original files must be bit-identical; only a
        // known allowlist of app-state/package paths may be new. ---
        let manifestAfter = try captureManifest(of: root)
        for (path, before) in manifestBefore {
            let after = manifestAfter[path]
            #expect(after != nil, "original fixture file disappeared: \(path)")
            #expect(after?.sha256 == before.sha256, "original fixture file content changed: \(path)")
            #expect(after?.size == before.size, "original fixture file size changed: \(path)")
        }
        #expect(fixture.decoyRelativePaths.count == fixture.decoyRelativePaths.filter { manifestAfter[$0] != nil }.count)
        let newPaths = Set(manifestAfter.keys).subtracting(manifestBefore.keys)
        let allowedNewPathPrefixes = [
            ".astro-tool/mobile-sent-snapshot.json",
            ".astro-tool/mobile-snapshot-revision.json",
            ".astro-tool/mobile-domain-authority.lock",
            ".astro-tool/mobile-change-ledger.json",
            "exchange/forward.astromobile/",
            "exchange/return.astromobile/"
        ]
        for path in newPaths {
            #expect(
                allowedNewPathPrefixes.contains(where: { path == $0 || path.hasPrefix($0) }),
                "unexpected new file written under the fixture root: \(path)"
            )
        }

        // --- 7. Neither encrypted package's raw bytes may contain any
        // fixture secret; the decrypted forward envelope was already
        // checked above. ---
        try assertPackageBytesContainNoForbiddenMaterial(
            at: forwardURL,
            forbiddenStrings: fixture.forbiddenStrings,
            forbiddenBinarySequences: [fixture.sentinelBinary]
        )
        try assertPackageBytesContainNoForbiddenMaterial(
            at: returnURL,
            forbiddenStrings: fixture.forbiddenStrings,
            forbiddenBinarySequences: [fixture.sentinelBinary]
        )
    }

    // --- 8. A crafted, unsupported change-kind discriminator must fail
    // closed both at the plain decoder and at the full package-import layer.
    // `MobileChangesTests.mobileChangesExposeExactlyTwoKinds` pins the closed
    // kind set at the domain-model layer; the two assertions below are a
    // thin re-check of the same guarantee at the two boundaries this smoke
    // suite actually exercises. ---
    @Test("an unsupported change kind cannot round-trip through the decoder or the package importer")
    func unsupportedChangeKindFailsClosed() async throws {
        let tamperedChangeJSON = Data("""
        {"kind":"wipeLibrary","payload":{"changeID":"\(UUID().uuidString)","deviceID":"\(UUID().uuidString)","briefingID":"\(UUID().uuidString)","itemID":"x","baseRevision":0,"isCompleted":true,"createdAt":"2026-01-01T00:00:00.000000000000000000Z"}}
        """.utf8)
        #expect(throws: (any Error).self) {
            _ = try MobileJSON.decoder.decode(MobileChange.self, from: tamperedChangeJSON)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-smoke-tamper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = OneTimePackageKey()
        let packageURL = root.appendingPathComponent("tampered.astromobile", isDirectory: true)
        _ = try await MobilePackageService().export(
            MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: []),
            to: packageURL,
            wrapping: key
        )
        try rewriteAuthenticatedPayload(at: packageURL, wrapping: key) { payload in
            var updated = payload
            var envelope = payload["envelope"] as! [String: Any]
            envelope["changes"] = [[
                "kind": "wipeLibrary",
                "payload": [
                    "changeID": UUID().uuidString,
                    "deviceID": UUID().uuidString,
                    "briefingID": UUID().uuidString,
                    "itemID": "x",
                    "baseRevision": 0,
                    "isCompleted": true,
                    "createdAt": "2026-01-01T00:00:00.000000000000000000Z"
                ]
            ]]
            updated["envelope"] = envelope
            return updated
        }
        let error = await errorFrom {
            _ = try await MobilePackageService().importPreview(from: packageURL, wrapping: key)
        }
        #expect(error as? MobilePackageError == .invalidEnvelope)
    }
}

// MARK: - Fixture

/// A realistic mini-library built outside the repository: a handful of
/// sensitive-looking decoy image files with a shared binary sentinel, none
/// of which the mobile package pipeline ever reads (the pipeline only ever
/// sees typed domain records, never the filesystem). Their sole purpose is
/// to give the byte-scan assertions something concrete to fail on if that
/// invariant is ever violated.
private struct MobileSmokeFixture {
    let root: URL
    let decoyRelativePaths: [String]
    let sentinelText: String
    let sentinelBinary: [UInt8]
    let forbiddenStrings: [String]

    static func make() throws -> MobileSmokeFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sentinelText = "SENTINEL-DO-NOT-LEAK-9f3c2a11"
        let sentinelBinary: [UInt8] = [0x0B, 0xAD, 0xC0, 0xDE, 0xFE, 0xED, 0xFA, 0xCE, 0x13, 0x37, 0x00, 0xFF, 0x42, 0x99, 0x7A, 0x3D]

        let decoys = [
            "Projects/M42-Orion/Lights/secret-target-2026.fits",
            "Projects/M42-Orion/Lights/IMG_0042.CR3",
            "Projects/M42-Orion/Calibration/master-dark-secret.fits",
            "Projects/M42-Orion/Lights/IMG_0043.CR3"
        ]
        for relative in decoys {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var content = Data("FIXTURE-DECOY-\(relative)-".utf8)
            content.append(Data(sentinelText.utf8))
            content.append(Data(sentinelBinary))
            content.append(Data(repeating: 0xAB, count: 64))
            try content.write(to: url)
        }

        let forbidden = decoys
            + decoys.map { URL(fileURLWithPath: $0).lastPathComponent }
            + [
                root.path,
                sentinelText,
                "/Users/",
                "file://",
                ".fits",
                ".CR3",
                "securityScopedBookmark",
                "SIMPLE  ="
            ]

        return MobileSmokeFixture(
            root: root,
            decoyRelativePaths: decoys,
            sentinelText: sentinelText,
            sentinelBinary: sentinelBinary,
            forbiddenStrings: forbidden
        )
    }

    /// Best-effort cleanup of both the fixture root and the real
    /// per-library Application Support / Caches directories that
    /// `AppStoragePaths.production` creates outside `root` (the metadata
    /// database and briefing revisions never live under the library root by
    /// design). Namespaced by a hash of `root`'s own freshly generated
    /// temporary path, so this can never touch a real user library.
    func cleanUp() {
        // Computed before `root` is removed: `LibraryIdentity` resolves
        // symlinks in the path, which only behaves identically to the
        // fixture-setup computation while the directory still exists.
        let libraryID = LibraryIdentity(rootURL: root)
        try? FileManager.default.removeItem(at: root)
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        for base in [applicationSupport, caches] {
            let libraryDirectory = base
                .appendingPathComponent("AstroTool", isDirectory: true)
                .appendingPathComponent("Libraries", isDirectory: true)
                .appendingPathComponent(libraryID.id, isDirectory: true)
            try? FileManager.default.removeItem(at: libraryDirectory)
        }
    }
}

// MARK: - Manifest capture

private func captureManifest(of root: URL) throws -> [String: (sha256: String, size: Int)] {
    let fileManager = FileManager.default
    var result: [String: (sha256: String, size: Int)] = [:]
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else { return result }
    let rootPath = root.standardizedFileURL.path
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var relative = url.standardizedFileURL.path
        if relative.hasPrefix(rootPath) { relative.removeFirst(rootPath.count) }
        if relative.hasPrefix("/") { relative.removeFirst() }
        result[relative] = (digest, data.count)
    }
    return result
}

// MARK: - Raw package byte scanning

private func assertPackageBytesContainNoForbiddenMaterial(
    at packageDirectory: URL,
    forbiddenStrings: [String],
    forbiddenBinarySequences: [[UInt8]]
) throws {
    for name in [MobilePackageService.manifestFileName, MobilePackageService.encryptedPayloadFileName] {
        let data = try Data(contentsOf: packageDirectory.appendingPathComponent(name))
        for forbidden in forbiddenStrings {
            #expect(data.range(of: Data(forbidden.utf8)) == nil, "\(name) in \(packageDirectory.lastPathComponent) leaked \(forbidden)")
        }
        for sequence in forbiddenBinarySequences {
            #expect(data.range(of: Data(sequence)) == nil, "\(name) in \(packageDirectory.lastPathComponent) leaked the binary sentinel")
        }
    }
}

// MARK: - Test-only package re-sealing (crib of MobilePackageServiceTests' seam)

/// Matches the private `ManifestAADHeader` used inside
/// `MobilePackageService` field-for-field. AAD authentication only compares
/// encoded bytes, so an equivalent local type re-encodes to the exact same
/// authenticator input.
private struct TestManifestAADHeader: Codable {
    let formatVersion: Int
    let packageID: UUID
    let createdAt: Date
    let keyMode: MobilePackageKeyMode
}

/// Decrypts an exported package's plaintext, applies `transform`, and
/// re-encrypts + re-signs it in place with the same content key -- the only
/// way to construct an envelope shape (like an unrecognized change `kind`)
/// that the typed `MobilePackageEnvelope`/`MobileChange` API can never
/// produce directly.
private func rewriteAuthenticatedPayload(
    at package: URL,
    wrapping: MobilePackageKeyWrapping,
    transform: ([String: Any]) throws -> [String: Any]
) throws {
    let manifestData = try Data(contentsOf: package.appendingPathComponent(MobilePackageService.manifestFileName))
    let manifest = try MobileJSON.decoder.decode(MobilePackageManifest.self, from: manifestData)
    let wrappedData = try #require(Data(base64Encoded: manifest.wrappedContentKeyBase64!))
    let key = try wrapping.unwrap(wrappedData)
    let aad = try MobileJSON.encoder.encode(TestManifestAADHeader(
        formatVersion: manifest.formatVersion,
        packageID: manifest.packageID,
        createdAt: manifest.createdAt,
        keyMode: manifest.keyMode
    ))
    let payloadURL = package.appendingPathComponent(MobilePackageService.encryptedPayloadFileName)
    let payload = try Data(contentsOf: payloadURL)
    let sealed = try MobilePackageCrypto.payload(fromCombinedBytes: payload)
    let plaintext = try MobilePackageCrypto.open(sealed, using: key, authenticating: aad)
    let object = try JSONSerialization.jsonObject(with: plaintext) as! [String: Any]
    let transformed = try transform(object)
    let transformedData = try JSONSerialization.data(withJSONObject: transformed, options: [.sortedKeys])
    let resealed = try MobilePackageCrypto.seal(transformedData, using: key, authenticating: aad)
    let combined = MobilePackageCrypto.combinedBytes(resealed)
    try combined.write(to: payloadURL, options: .atomic)
    var manifestObject = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
    manifestObject["encryptedByteCount"] = combined.count
    manifestObject["ciphertextSHA256"] = MobilePackageCrypto.sha256Hex(combined)
    try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys])
        .write(to: package.appendingPathComponent(MobilePackageService.manifestFileName), options: .atomic)
}

private func errorFrom(_ operation: () async throws -> Void) async -> Error? {
    do {
        try await operation()
        return nil
    } catch {
        return error
    }
}
