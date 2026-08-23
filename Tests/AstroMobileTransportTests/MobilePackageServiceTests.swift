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
    #expect(exportError is MobilePackageError)
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
    #expect(wrongKeyError is MobilePackageError)
    var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as! [String: Any]
    manifest["ciphertextSHA256"] = String(repeating: "0", count: 64)
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
    let hashError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: destination, wrapping: DeterministicWrapper())
    }
    #expect(hashError is MobilePackageError)
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
        #expect(error is MobilePackageError)
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
    #expect(schemaError is MobilePackageError)
    try await MobilePackageService().export(envelope, to: root.url.appendingPathComponent("valid.astromobile"), wrapping: DeterministicWrapper())
    let payloadURL = root.url.appendingPathComponent("valid.astromobile/encrypted-payload.bin")
    let payload = try Data(contentsOf: payloadURL)
    try payload.dropLast().write(to: payloadURL, options: .atomic)
    let truncationError = await errorFrom {
        _ = try await MobilePackageService().importPreview(from: root.url.appendingPathComponent("valid.astromobile"), wrapping: DeterministicWrapper())
    }
    #expect(truncationError is MobilePackageError)
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
    #expect(duplicatePreviewError is MobilePackageError)
    _ = try await service.commitImport(packageID: preview.packageID)
    let duplicateCommitError = await errorFrom {
        _ = try await service.commitImport(packageID: preview.packageID)
    }
    #expect(duplicateCommitError is MobilePackageError)
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
