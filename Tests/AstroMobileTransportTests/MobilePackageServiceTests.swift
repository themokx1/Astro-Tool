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
