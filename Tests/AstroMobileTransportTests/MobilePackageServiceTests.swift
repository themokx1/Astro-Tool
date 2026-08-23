import CryptoKit
import Foundation
import Testing
@testable import AstroMobileTransport
@testable import AstroMobileDomain

private struct DeterministicWrapper: MobilePackageKeyWrapping {
    func wrap(_ key: SymmetricKey) throws -> Data { key.withUnsafeBytes { Data($0) } }
    func unwrap(_ wrapped: Data) throws -> SymmetricKey { SymmetricKey(data: wrapped) }
}

private struct WrongWrapper: MobilePackageKeyWrapping {
    let key: SymmetricKey
    func wrap(_ key: SymmetricKey) throws -> Data { key.withUnsafeBytes { Data($0) } }
    func unwrap(_ wrapped: Data) throws -> SymmetricKey { key }
}

@Test func exportAndImportPreviewRoundTrip() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("mobile.astromobile")
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    let service = MobilePackageService()
    try await service.export(envelope, to: destination, wrapping: DeterministicWrapper())
    let preview = try await service.importPreview(from: destination, wrapping: DeterministicWrapper())
    #expect(preview.incomingChanges.isEmpty)
    #expect(try await service.commitImport(packageID: preview.packageID) == envelope)
}

@Test func composedSnapshotWithOmittedOptionalFieldsRoundTrips() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("composed.astromobile")
    let projectID = UUID(), nightID = UUID(), captureID = UUID(), briefingID = UUID()
    let noteID = "briefing-note"
    let snapshot = MobileLibrarySnapshot(
        schemaVersion: MobileLibrarySnapshot.currentSchemaVersion,
        libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 3,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        projects: [MobileProject(id: projectID, displayName: "M31", catalogID: "catalog", phase: "ready", integrationSeconds: 12, goalHours: nil)],
        nights: [MobileNight(id: nightID, localDate: "2026-08-23", timeZoneID: "Europe/Budapest")],
        captures: [MobileCapture(id: captureID, projectID: projectID, nightID: nightID, displayName: "L", filterName: nil, exposureSeconds: 30, integrationSeconds: 60)],
        briefings: [MobileBriefing(id: briefingID, revision: 1, savedAt: Date(timeIntervalSince1970: 1_700_000_001), nightDate: nil, readiness: "ready", targets: [], checklist: [MobileChecklistSection(id: "section", title: "Basics", items: [MobileChecklistItem(id: "item", title: "Focus", explanation: nil, isCompleted: false, baseRevision: 0)])], noteID: noteID)],
        notes: [MobileNote(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: "", baseRevision: 0, updatedAt: Date(timeIntervalSince1970: 1_700_000_002), isEditableOnPhone: true)]
    )
    let envelope = MobilePackageEnvelope(snapshot: snapshot, changes: [], acknowledgedChangeIDs: [])
    let service = MobilePackageService()
    try await service.export(envelope, to: destination, wrapping: DeterministicWrapper())
    let preview = try await service.importPreview(from: destination, wrapping: DeterministicWrapper())
    #expect(try await service.commitImport(packageID: preview.packageID) == envelope)
}

@Test func nestedUnknownAndLibraryIDFieldsFailClosed() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("nested-unknown.astromobile")
    let noteID = "note"
    let snapshot = MobileLibrarySnapshot(schemaVersion: 1, libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 0, createdAt: Date(), projects: [], nights: [], captures: [], briefings: [], notes: [MobileNote(id: noteID, scope: .project, ownerID: "p", text: "", baseRevision: 0, updatedAt: Date(), isEditableOnPhone: true)])
    try await MobilePackageService().export(MobilePackageEnvelope(snapshot: snapshot, changes: [], acknowledgedChangeIDs: []), to: destination, wrapping: DeterministicWrapper())
    try rewriteAuthenticatedPayload(at: destination) { payload in
        var updated = payload
        var envelope = payload["envelope"] as! [String: Any]
        var snapshot = envelope["snapshot"] as! [String: Any]
        let library = snapshot["libraryID"] as! [String: Any]
        snapshot["libraryID"] = ["rawValue": library["rawValue"]!, "forbidden": true]
        envelope["snapshot"] = snapshot
        updated["envelope"] = envelope
        return updated
    }
    let error = await errorFrom { _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper()) }
    #expect(error as? MobilePackageError == .invalidEnvelope)
}

@Test func existingDestinationIsNeverOverwritten() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("mobile.astromobile")
    try Data("sentinel".utf8).write(to: destination)
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    let exportError = await errorFrom {
        try await MobilePackageService().export(
            envelope,
            to: destination,
            wrapping: DeterministicWrapper()
        )
    }
    #expect(exportError as? MobilePackageError == .destinationExists)
    #expect(try Data(contentsOf: destination) == Data("sentinel".utf8))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.url.path).filter { $0.contains(".mobile.astromobile.staging-") }
    #expect(leftovers.isEmpty)
}

@Test func wrongKeyAndTamperedManifestAreRejected() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("mobile.astromobile")
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    try await MobilePackageService().export(envelope, to: destination, wrapping: DeterministicWrapper())
    let wrongKeyError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: destination, wrapping: WrongWrapper(key: SymmetricKey(size: .bits256)))
    }
    #expect(wrongKeyError as? MobilePackageError == .authenticationFailed)
    var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as! [String: Any]
    manifest["ciphertextSHA256"] = String(repeating: "0", count: 64)
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
    let hashError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper())
    }
    #expect(hashError as? MobilePackageError == .manifestHashMismatch)
}

@Test func tamperedManifestIdentityIsAuthenticatedAndRejected() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("identity.astromobile")
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    try await MobilePackageService().export(envelope, to: destination, wrapping: DeterministicWrapper())
    var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as! [String: Any]
    manifest["packageID"] = UUID().uuidString
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
    let error = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper())
    }
    #expect(error as? MobilePackageError == .authenticationFailed)
}

@Test func tamperingEachAuthenticatedPayloadComponentIsRejected() async throws {
    let root = try TemporaryPackageDirectory()
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    for component in ["nonce", "ciphertext", "tag"] {
        let destination = root.url.appendingPathComponent("\(component).astromobile")
        try await MobilePackageService().export(envelope, to: destination, wrapping: DeterministicWrapper())
        let payloadURL = destination.appendingPathComponent("encrypted-payload.bin")
        var payload = try Data(contentsOf: payloadURL)
        let index: Int
        switch component {
        case "nonce": index = 0
        case "ciphertext": index = MobilePackageCrypto.nonceByteCount
        default: index = payload.count - 1
        }
        payload[index] ^= 1
        try payload.write(to: payloadURL, options: .atomic)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as! [String: Any]
        manifest["ciphertextSHA256"] = MobilePackageCrypto.sha256Hex(payload)
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
        let error = await errorFrom {
            _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper())
        }
        #expect(error as? MobilePackageError == .authenticationFailed)
    }
}

@Test func unsupportedSchemaAndTruncatedPayloadAreRejected() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("mobile.astromobile")
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    try await MobilePackageService().export(envelope, to: destination, wrapping: DeterministicWrapper())
    var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as! [String: Any]
    manifest["formatVersion"] = 99
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
    let schemaError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper())
    }
    #expect(schemaError as? MobilePackageError == .unsupportedFormatVersion)
    try await MobilePackageService().export(envelope, to: root.url.appendingPathComponent("valid.astromobile"), wrapping: DeterministicWrapper())
    let payloadURL = root.url.appendingPathComponent("valid.astromobile/encrypted-payload.bin")
    let payload = try Data(contentsOf: payloadURL)
    try payload.dropLast().write(to: payloadURL, options: .atomic)
    let truncationError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: root.url.appendingPathComponent("valid.astromobile"), wrapping: DeterministicWrapper())
    }
    #expect(truncationError as? MobilePackageError == .manifestHashMismatch)
}

@Test func duplicatePreviewAndCommitAreRejected() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("mobile.astromobile")
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    let service = MobilePackageService()
    try await service.export(envelope, to: destination, wrapping: DeterministicWrapper())
    let preview = try await service.importPreview(from: destination, wrapping: DeterministicWrapper())
    let duplicatePreviewError = await errorFrom {
        _ = try await service.importPreview(from: destination, wrapping: DeterministicWrapper())
    }
    #expect(duplicatePreviewError as? MobilePackageError == .duplicatePackageID)
    _ = try await service.commitImport(packageID: preview.packageID)
    let duplicateCommitError = await errorFrom {
        _ = try await service.commitImport(packageID: preview.packageID)
    }
    #expect(duplicateCommitError as? MobilePackageError == .duplicatePackageID)
}

@Test func unknownEnvelopeFieldsAndFutureSnapshotSchemaFailClosed() async throws {
    let root = try TemporaryPackageDirectory()
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    let unknownURL = root.url.appendingPathComponent("unknown.astromobile")
    try await MobilePackageService().export(envelope, to: unknownURL, wrapping: DeterministicWrapper())
    try rewriteAuthenticatedPayload(at: unknownURL) { payload in
        var updated = payload
        var envelope = payload["envelope"] as! [String: Any]
        envelope["forbiddenPath"] = "/Users/private"
        updated["envelope"] = envelope
        return updated
    }
    let unknownError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: unknownURL, wrapping: DeterministicWrapper())
    }
    #expect(unknownError as? MobilePackageError == .invalidEnvelope)

    let futureURL = root.url.appendingPathComponent("future.astromobile")
    try await MobilePackageService().export(envelope, to: futureURL, wrapping: DeterministicWrapper())
    try rewriteAuthenticatedPayload(at: futureURL) { payload in
        var updated = payload
        var envelope = payload["envelope"] as! [String: Any]
        envelope["snapshot"] = [
            "schemaVersion": MobileLibrarySnapshot.currentSchemaVersion + 1,
            "libraryID": ["rawValue": UUID().uuidString], "snapshotID": UUID().uuidString,
            "revision": 1, "createdAt": "2026-08-23T00:00:00.00000000000000000Z",
            "projects": [], "nights": [], "captures": [], "briefings": [], "notes": []
        ]
        updated["envelope"] = envelope
        return updated
    }
    let futureError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: futureURL, wrapping: DeterministicWrapper())
    }
    #expect(futureError as? MobilePackageError == .unsupportedSchemaVersion)
}

@Test func manifestAndNestedCollectionLimitsFailBeforeStaging() async throws {
    let root = try TemporaryPackageDirectory()
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    let oversizedManifestURL = root.url.appendingPathComponent("oversized-manifest.astromobile")
    try await MobilePackageService().export(envelope, to: oversizedManifestURL, wrapping: DeterministicWrapper())
    try Data(repeating: 0, count: MobilePackageService.maximumManifestByteCount + 1)
        .write(to: oversizedManifestURL.appendingPathComponent("manifest.json"), options: .atomic)
    let manifestError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: oversizedManifestURL, wrapping: DeterministicWrapper())
    }
    #expect(manifestError as? MobilePackageError == .invalidManifest)

    let collectionURL = root.url.appendingPathComponent("oversized-collection.astromobile")
    try await MobilePackageService().export(envelope, to: collectionURL, wrapping: DeterministicWrapper())
    try rewriteAuthenticatedPayload(at: collectionURL) { payload in
        var updated = payload
        var envelope = payload["envelope"] as! [String: Any]
        envelope["changes"] = Array(repeating: ["kind": "noteRevision", "payload": [
            "changeID": UUID().uuidString, "deviceID": UUID().uuidString, "noteID": "n", "ownerID": "o",
            "baseRevision": 0, "text": "x", "createdAt": "2026-08-23T00:00:00.00000000000000000Z"
        ]], count: MobilePackageService.maximumCollectionCount + 1)
        updated["envelope"] = envelope
        return updated
    }
    let collectionError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: collectionURL, wrapping: DeterministicWrapper())
    }
    #expect(collectionError as? MobilePackageError == .invalidEnvelope)
}

@Test func tokenExplosionAndOversizedExportFailWithExactErrors() async throws {
    let root = try TemporaryPackageDirectory()
    let tokenURL = root.url.appendingPathComponent("token.astromobile")
    let empty = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    try await MobilePackageService().export(empty, to: tokenURL, wrapping: DeterministicWrapper())
    let manifest = try MobileJSON.decoder.decode(MobilePackageManifest.self, from: Data(contentsOf: tokenURL.appendingPathComponent("manifest.json")))
    let nested = String(repeating: "[", count: MobilePackageService.maximumJSONDepth + 2) + "null" + String(repeating: "]", count: MobilePackageService.maximumJSONDepth + 2)
    let raw = Data("{\"packageID\":\"\(manifest.packageID.uuidString)\",\"envelope\":{\"changes\":[],\"acknowledgedChangeIDs\":[],\"snapshot\":\(nested)}}".utf8)
    try rewriteAuthenticatedPayloadRaw(at: tokenURL, plaintext: raw)
    let tokenError = await errorFrom { _ = try await MobilePackageService().importPreview(from: tokenURL, wrapping: DeterministicWrapper()) }
    #expect(tokenError as? MobilePackageError == .invalidEnvelope)

    let oversizedNote = MobileNote(id: "n", scope: .project, ownerID: "p", text: String(repeating: "x", count: MobilePackageService.maximumStringByteCount + 1), baseRevision: 0, updatedAt: Date(), isEditableOnPhone: true)
    let oversizedSnapshot = MobileLibrarySnapshot(schemaVersion: 1, libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 0, createdAt: Date(), projects: [], nights: [], captures: [], briefings: [], notes: [oversizedNote])
    let oversizedError = await errorFrom {
        try await MobilePackageService().export(MobilePackageEnvelope(snapshot: oversizedSnapshot, changes: [], acknowledgedChangeIDs: []), to: root.url.appendingPathComponent("oversized.astromobile"), wrapping: DeterministicWrapper())
    }
    #expect(oversizedError as? MobilePackageError == .invalidEnvelope)
}

@Test func lexicalUnicodeBoundariesAndTrailingDataFailClosed() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("lexical.astromobile")
    try await MobilePackageService().export(MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: []), to: destination, wrapping: DeterministicWrapper())
    let manifest = try MobileJSON.decoder.decode(MobilePackageManifest.self, from: Data(contentsOf: destination.appendingPathComponent("manifest.json")))
    let prefix = "{\"packageID\":\"\(manifest.packageID.uuidString)\",\"envelope\":{\"changes\":[],\"acknowledgedChangeIDs\":[],\"x\":\""
    let suffix = "\"}}"
    for value in ["\\uD83D\\uDE00", "\\uD800", String(repeating: "a", count: 129)] {
        let raw = Data((prefix + value + suffix).utf8)
        try rewriteAuthenticatedPayloadRaw(at: destination, plaintext: raw)
        let error = await errorFrom { _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper()) }
        #expect(error as? MobilePackageError == .invalidEnvelope)
    }
    let trailing = Data(("{\"packageID\":\"\(manifest.packageID.uuidString)\",\"envelope\":{\"changes\":[],\"acknowledgedChangeIDs\":[]}}x").utf8)
    try rewriteAuthenticatedPayloadRaw(at: destination, plaintext: trailing)
    let trailingError = await errorFrom { _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper()) }
    #expect(trailingError as? MobilePackageError == .invalidEnvelope)
}

@Test func wrappedKeyEncodingAndDecodedSizeAreBounded() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("wrapped.astromobile")
    try await MobilePackageService().export(MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: []), to: destination, wrapping: DeterministicWrapper())
    var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as! [String: Any]
    manifest["wrappedContentKeyBase64"] = Data(repeating: 0, count: MobilePackageService.maximumWrappedKeyByteCount + 1).base64EncodedString()
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
    let oversizedError = await errorFrom { _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper()) }
    #expect(oversizedError as? MobilePackageError == .invalidManifest)

    try await MobilePackageService().export(MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: []), to: root.url.appendingPathComponent("canonical.astromobile"), wrapping: DeterministicWrapper())
    let canonicalURL = root.url.appendingPathComponent("canonical.astromobile/manifest.json")
    var noncanonical = try JSONSerialization.jsonObject(with: Data(contentsOf: canonicalURL)) as! [String: Any]
    let encoded = noncanonical["wrappedContentKeyBase64"] as! String
    noncanonical["wrappedContentKeyBase64"] = String(encoded.dropLast())
    try JSONSerialization.data(withJSONObject: noncanonical, options: [.sortedKeys]).write(to: canonicalURL, options: .atomic)
    let noncanonicalError = await errorFrom { _ = try await MobilePackageService().importPreview(from: root.url.appendingPathComponent("canonical.astromobile"), wrapping: DeterministicWrapper()) }
    #expect(noncanonicalError as? MobilePackageError == .invalidManifest)
}

@Test func decodableNonCanonicalWrappedKeyBase64IsRejected() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("noncanonical-base64.astromobile")
    try await MobilePackageService().export(MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: []), to: destination, wrapping: DeterministicWrapper())
    let manifestURL = destination.appendingPathComponent("manifest.json")
    var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
    let canonical = manifest["wrappedContentKeyBase64"] as! String
    let noncanonical = decodableNonCanonicalBase64(canonical)
    #expect(noncanonical != nil)
    guard let noncanonical else { return }
    manifest["wrappedContentKeyBase64"] = noncanonical
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
    let error = await errorFrom { _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper()) }
    #expect(error as? MobilePackageError == .invalidManifest)
}

@Test func aggregateWarningsAndNestedArraysFailBeforePublication() async throws {
    let root = try TemporaryPackageDirectory()
    let target = MobileBriefingTarget(id: UUID(), name: "target", role: "role", start: Date(), end: Date(), warnings: Array(repeating: "warning", count: MobilePackageService.maximumCollectionCount + 1))
    let note = MobileNote(id: "note", scope: .briefing, ownerID: UUID().uuidString, text: "", baseRevision: 0, updatedAt: Date(), isEditableOnPhone: true)
    let briefing = MobileBriefing(id: UUID(), revision: 0, savedAt: Date(), nightDate: nil, readiness: "ready", targets: [target], checklist: [], noteID: note.id)
    let snapshot = MobileLibrarySnapshot(schemaVersion: 1, libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 0, createdAt: Date(), projects: [], nights: [], captures: [], briefings: [briefing], notes: [note])
    let error = await errorFrom { try await MobilePackageService().export(MobilePackageEnvelope(snapshot: snapshot, changes: [], acknowledgedChangeIDs: []), to: root.url.appendingPathComponent("aggregate.astromobile"), wrapping: DeterministicWrapper()) }
    #expect(error as? MobilePackageError == .invalidEnvelope)
    #expect(!(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("aggregate.astromobile").path)))
}

@Test func escapedWarningsAndEmptyWarningCountsFailBeforeEncoding() async throws {
    let root = try TemporaryPackageDirectory()
    let briefingID = UUID()
    let note = MobileNote(id: "note", scope: .briefing, ownerID: briefingID.uuidString, text: "", baseRevision: 0, updatedAt: Date(), isEditableOnPhone: true)
    let target = MobileBriefingTarget(
        id: UUID(), name: "target", role: "role", start: Date(), end: Date(),
        warnings: Array(repeating: String(repeating: "\u{0001}", count: 200), count: MobilePackageService.maximumCollectionCount)
    )
    let briefing = MobileBriefing(id: briefingID, revision: 0, savedAt: Date(), nightDate: nil, readiness: "ready", targets: [target], checklist: [], noteID: note.id)
    let snapshot = MobileLibrarySnapshot(schemaVersion: 1, libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 0, createdAt: Date(), projects: [], nights: [], captures: [], briefings: [briefing], notes: [note])
    let escapedDestination = root.url.appendingPathComponent("escaped.astromobile")
    let escapedError = await errorFrom {
        try await MobilePackageService().export(MobilePackageEnvelope(snapshot: snapshot, changes: [], acknowledgedChangeIDs: []), to: escapedDestination, wrapping: DeterministicWrapper())
    }
    #expect(escapedError as? MobilePackageError == .invalidEnvelope)
    #expect(!FileManager.default.fileExists(atPath: escapedDestination.path))

    let oversizedTarget = MobileBriefingTarget(id: UUID(), name: "target", role: "role", start: Date(), end: Date(), warnings: Array(repeating: "", count: MobilePackageService.maximumCollectionCount + 1))
    let oversizedBriefing = MobileBriefing(id: briefingID, revision: 0, savedAt: Date(), nightDate: nil, readiness: "ready", targets: [oversizedTarget], checklist: [], noteID: note.id)
    let oversizedSnapshot = MobileLibrarySnapshot(schemaVersion: 1, libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 0, createdAt: Date(), projects: [], nights: [], captures: [], briefings: [oversizedBriefing], notes: [note])
    let countError = await errorFrom {
        try await MobilePackageService().export(MobilePackageEnvelope(snapshot: oversizedSnapshot, changes: [], acknowledgedChangeIDs: []), to: root.url.appendingPathComponent("too-many-empty.astromobile"), wrapping: DeterministicWrapper())
    }
    #expect(countError as? MobilePackageError == .invalidEnvelope)
}

@Test func publicationReplacementFailsWithoutDeletingReplacement() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("replacement.astromobile")
    let replacedStagingURL = URLStore()
    let service = MobilePackageService(testingBeforePublication: { url in
        replacedStagingURL.value = url
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try? Data("replacement".utf8).write(to: url.appendingPathComponent("sentinel"))
    })
    let error = await errorFrom {
        try await service.export(MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: []), to: destination, wrapping: DeterministicWrapper())
    }
    #expect(error as? MobilePackageError == .stagingFailed)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let stagingURL = try #require(replacedStagingURL.value)
    #expect(try Data(contentsOf: stagingURL.appendingPathComponent("sentinel")) == Data("replacement".utf8))
    try FileManager.default.removeItem(at: stagingURL)
}

@Test func lexicalSurrogateAndDecodedKeyBoundariesAreIndependentOfSchema() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("unicode.astromobile")
    try await MobilePackageService().export(MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: []), to: destination, wrapping: DeterministicWrapper())
    let manifest = try MobileJSON.decoder.decode(MobilePackageManifest.self, from: Data(contentsOf: destination.appendingPathComponent("manifest.json")))
    let createdAt = "2026-08-23T00:00:00.00000000000000000Z"
    let valid = Data("{\"packageID\":\"\(manifest.packageID.uuidString)\",\"envelope\":{\"changes\":[{\"kind\":\"noteRevision\",\"payload\":{\"changeID\":\"\(UUID().uuidString)\",\"deviceID\":\"\(UUID().uuidString)\",\"noteID\":\"n\",\"ownerID\":\"o\",\"baseRevision\":0,\"text\":\"\\uD83D\\uDE00\",\"createdAt\":\"\(createdAt)\"}}],\"acknowledgedChangeIDs\":[]}}".utf8)
    try rewriteAuthenticatedPayloadRaw(at: destination, plaintext: valid)
    let preview = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper())
    #expect(preview.incomingChanges.count == 1)

    let tooLongKey = String(repeating: "a", count: 129)
    let malformed = Data("{\"\(tooLongKey)\":null}".utf8)
    try rewriteAuthenticatedPayloadRaw(at: destination, plaintext: malformed)
    let error = await errorFrom { _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper()) }
    #expect(error as? MobilePackageError == .invalidEnvelope)
}

@Test func hardlinkedChildrenAreRejected() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("hardlink.astromobile")
    try await MobilePackageService().export(MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: []), to: destination, wrapping: DeterministicWrapper())
    let original = root.url.appendingPathComponent("payload-copy.bin")
    let payload = destination.appendingPathComponent("encrypted-payload.bin")
    try FileManager.default.copyItem(at: payload, to: original)
    try FileManager.default.removeItem(at: payload)
    try FileManager.default.linkItem(at: original, to: payload)
    let error = await errorFrom { _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper()) }
    #expect(error as? MobilePackageError == .malformedPackage)
}

@Test func semanticReferencesAreValidatedExactly() async throws {
    let root = try TemporaryPackageDirectory()
    let note = MobileNote(id: "note", scope: .briefing, ownerID: "owner", text: "", baseRevision: 0, updatedAt: Date(), isEditableOnPhone: false)
    let briefing = MobileBriefing(id: UUID(), revision: 0, savedAt: Date(), nightDate: nil, readiness: "ready", targets: [], checklist: [MobileChecklistSection(id: "a", title: "A", items: [MobileChecklistItem(id: "same", title: "1", explanation: nil, isCompleted: false, baseRevision: 0)]), MobileChecklistSection(id: "b", title: "B", items: [MobileChecklistItem(id: "same", title: "2", explanation: nil, isCompleted: false, baseRevision: 0)])], noteID: note.id)
    let snapshot = MobileLibrarySnapshot(schemaVersion: 1, libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 0, createdAt: Date(), projects: [], nights: [], captures: [], briefings: [briefing], notes: [note])
    let duplicateError = await errorFrom { try await MobilePackageService().export(MobilePackageEnvelope(snapshot: snapshot, changes: [], acknowledgedChangeIDs: []), to: root.url.appendingPathComponent("duplicate.astromobile"), wrapping: DeterministicWrapper()) }
    #expect(duplicateError as? MobilePackageError == .invalidEnvelope)

    let missingRef = MobileBriefing(id: UUID(), revision: 0, savedAt: Date(), nightDate: nil, readiness: "ready", targets: [], checklist: [], noteID: "missing")
    let missingSnapshot = MobileLibrarySnapshot(schemaVersion: 1, libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 0, createdAt: Date(), projects: [], nights: [], captures: [], briefings: [missingRef], notes: [])
    let missingError = await errorFrom { try await MobilePackageService().export(MobilePackageEnvelope(snapshot: missingSnapshot, changes: [], acknowledgedChangeIDs: []), to: root.url.appendingPathComponent("missing.astromobile"), wrapping: DeterministicWrapper()) }
    #expect(missingError as? MobilePackageError == .invalidEnvelope)

    let editableNote = MobileNote(id: "editable", scope: .briefing, ownerID: "owner", text: "", baseRevision: 0, updatedAt: Date(), isEditableOnPhone: true)
    let wrongOwnerChange = MobileChange.noteRevision(NoteRevisionChange(changeID: UUID(), deviceID: UUID(), noteID: editableNote.id, ownerID: "wrong", baseRevision: 0, text: "x", createdAt: Date()))
    let wrongOwnerError = await errorFrom { try await MobilePackageService().export(MobilePackageEnvelope(snapshot: MobileLibrarySnapshot(schemaVersion: 1, libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 0, createdAt: Date(), projects: [], nights: [], captures: [], briefings: [], notes: [editableNote]), changes: [wrongOwnerChange], acknowledgedChangeIDs: []), to: root.url.appendingPathComponent("wrong-owner.astromobile"), wrapping: DeterministicWrapper()) }
    #expect(wrongOwnerError as? MobilePackageError == .invalidEnvelope)
    let nonEditableChange = MobileChange.noteRevision(NoteRevisionChange(changeID: UUID(), deviceID: UUID(), noteID: note.id, ownerID: note.ownerID, baseRevision: 0, text: "x", createdAt: Date()))
    let nonEditableError = await errorFrom { try await MobilePackageService().export(MobilePackageEnvelope(snapshot: MobileLibrarySnapshot(schemaVersion: 1, libraryID: PortableLibraryID(rawValue: UUID()), snapshotID: UUID(), revision: 0, createdAt: Date(), projects: [], nights: [], captures: [], briefings: [], notes: [note]), changes: [nonEditableChange], acknowledgedChangeIDs: []), to: root.url.appendingPathComponent("noneditable.astromobile"), wrapping: DeterministicWrapper()) }
    #expect(nonEditableError as? MobilePackageError == .invalidEnvelope)
}

@Test func importDoesNotModifySourceAndRejectsSymlinkedChildren() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("source.astromobile")
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    try await MobilePackageService().export(envelope, to: destination, wrapping: DeterministicWrapper())
    let before = try Data(contentsOf: destination.appendingPathComponent("encrypted-payload.bin"))
    let preview = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper())
    #expect(preview.incomingChanges.isEmpty)
    #expect(try Data(contentsOf: destination.appendingPathComponent("encrypted-payload.bin")) == before)

    let linked = root.url.appendingPathComponent("linked.astromobile")
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("manifest.json"), withDestinationURL: destination.appendingPathComponent("manifest.json"))
    try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("encrypted-payload.bin"), withDestinationURL: destination.appendingPathComponent("encrypted-payload.bin"))
    let symlinkError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: linked, wrapping: DeterministicWrapper())
    }
    #expect(symlinkError as? MobilePackageError == .malformedPackage)
}

@Test func replayIsActorScopedAndDurableIdempotencyIsDeferred() async throws {
    let root = try TemporaryPackageDirectory()
    let destination = root.url.appendingPathComponent("replay.astromobile")
    let envelope = MobilePackageEnvelope(snapshot: nil, changes: [], acknowledgedChangeIDs: [])
    try await MobilePackageService().export(envelope, to: destination, wrapping: DeterministicWrapper())
    let firstService = MobilePackageService()
    let secondService = MobilePackageService()
    let first = try await firstService.importPreview(from: destination, wrapping: DeterministicWrapper())
    let second = try await secondService.importPreview(from: destination, wrapping: DeterministicWrapper())
    #expect(first.packageID == second.packageID)
    _ = try await firstService.commitImport(packageID: first.packageID)
    let replayError = await errorFrom {
        _ = try await firstService.commitImport(packageID: first.packageID)
    }
    #expect(replayError as? MobilePackageError == .duplicatePackageID)
}

private struct TestManifestAADHeader: Codable {
    let formatVersion: Int
    let packageID: UUID
    let createdAt: Date
    let keyMode: MobilePackageKeyMode
}

private func rewriteAuthenticatedPayload(at package: URL, transform: ([String: Any]) throws -> [String: Any]) throws {
    let manifestData = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
    let manifest = try MobileJSON.decoder.decode(MobilePackageManifest.self, from: manifestData)
    let wrapped = Data(base64Encoded: manifest.wrappedContentKeyBase64!)!
    let key = SymmetricKey(data: wrapped)
    let payloadURL = package.appendingPathComponent("encrypted-payload.bin")
    let payload = try Data(contentsOf: payloadURL)
    let sealed = try MobilePackageCrypto.payload(fromCombinedBytes: payload)
    let aad = try MobileJSON.encoder.encode(TestManifestAADHeader(formatVersion: manifest.formatVersion, packageID: manifest.packageID, createdAt: manifest.createdAt, keyMode: manifest.keyMode))
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
    try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys]).write(to: package.appendingPathComponent("manifest.json"), options: .atomic)
}

private func rewriteAuthenticatedPayloadRaw(at package: URL, plaintext: Data) throws {
    let manifestData = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
    let manifest = try MobileJSON.decoder.decode(MobilePackageManifest.self, from: manifestData)
    let key = SymmetricKey(data: Data(base64Encoded: manifest.wrappedContentKeyBase64!)!)
    let payloadURL = package.appendingPathComponent("encrypted-payload.bin")
    let aad = try MobileJSON.encoder.encode(TestManifestAADHeader(formatVersion: manifest.formatVersion, packageID: manifest.packageID, createdAt: manifest.createdAt, keyMode: manifest.keyMode))
    let combined = MobilePackageCrypto.combinedBytes(try MobilePackageCrypto.seal(plaintext, using: key, authenticating: aad))
    try combined.write(to: payloadURL, options: .atomic)
    var manifestObject = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
    manifestObject["encryptedByteCount"] = combined.count
    manifestObject["ciphertextSHA256"] = MobilePackageCrypto.sha256Hex(combined)
    try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys]).write(to: package.appendingPathComponent("manifest.json"), options: .atomic)
}

private func decodableNonCanonicalBase64(_ canonical: String) -> String? {
    guard let decoded = Data(base64Encoded: canonical) else {
        return nil
    }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    var characters = Array(canonical)
    guard let padding = characters.firstIndex(of: "="), padding > 0 else { return nil }
    let lastDataIndex = padding - 1
    guard let position = alphabet.firstIndex(of: characters[lastDataIndex]) else { return nil }
    let groupStart = position & ~3
    for offset in 0..<4 where groupStart + offset != position {
        characters[lastDataIndex] = alphabet[groupStart + offset]
        let candidate = String(characters)
        if Data(base64Encoded: candidate) == decoded, candidate != canonical, decoded.base64EncodedString() != candidate {
            return candidate
        }
    }
    return nil
}

private final class URLStore: @unchecked Sendable {
    var value: URL?
}

private func errorFrom(_ operation: () async throws -> Void) async -> Error? {
    do {
        try await operation()
        return nil
    } catch {
        return error
    }
}

private struct TemporaryPackageDirectory: ~Copyable {
    let url: URL
    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AstroMobileTransport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.url = url
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
