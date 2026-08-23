import CryptoKit
import Foundation
import AstroMobileDomain

public struct MobilePackageImportPreview: Equatable, Sendable {
    public let packageID: UUID
    public let snapshotSummary: MobileSnapshotSummary
    public let incomingChanges: [MobileChange]
    public let encryptedByteCount: Int64

    public init(
        packageID: UUID,
        snapshotSummary: MobileSnapshotSummary,
        incomingChanges: [MobileChange],
        encryptedByteCount: Int64
    ) {
        self.packageID = packageID
        self.snapshotSummary = snapshotSummary
        self.incomingChanges = incomingChanges
        self.encryptedByteCount = encryptedByteCount
    }
}

public actor MobilePackageService {
    public static let manifestFileName = "manifest.json"
    public static let encryptedPayloadFileName = "encrypted-payload.bin"
    public static let currentFormatVersion = MobilePackageManifest.currentFormatVersion

    private static let maximumEncryptedByteCount: Int64 = 256 * 1024 * 1024
    private static let maximumCollectionCount = 100_000
    private static let maximumStringLength = 1_000_000

    private struct StagedImport: Sendable {
        let envelope: MobilePackageEnvelope
        let preview: MobilePackageImportPreview
    }

    private var stagedImports: [UUID: StagedImport] = [:]
    private var consumedPackageIDs: Set<UUID> = []

    public init() {}

    public func export(
        _ envelope: MobilePackageEnvelope,
        to destination: URL,
        wrapping: MobilePackageKeyWrapping
    ) throws {
        try Self.validateEnvelope(envelope)
        let packageID = UUID()
        let contentKey = SymmetricKey(size: .bits256)
        let plaintext = try MobileJSON.encoder.encode(envelope)
        let sealed = try MobilePackageCrypto.seal(plaintext, using: contentKey)
        let combined = MobilePackageCrypto.combinedBytes(sealed)
        let wrappedKey = try wrapping.wrap(contentKey)
        guard !wrappedKey.isEmpty else { throw MobilePackageError.invalidKey }

        let manifest = MobilePackageManifest(
            formatVersion: Self.currentFormatVersion,
            packageID: packageID,
            createdAt: Date(),
            encryptedByteCount: Int64(combined.count),
            ciphertextSHA256: MobilePackageCrypto.sha256Hex(combined),
            keyMode: wrapping is OneTimePackageKey ? .oneTimeQR : .pairedDevice,
            wrappedContentKeyBase64: wrappedKey.base64EncodedString()
        )

        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw MobilePackageError.destinationExists
            }
            guard fileManager.fileExists(atPath: parent.path) else {
                throw MobilePackageError.stagingFailed
            }
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
            try combined.write(to: temporary.appendingPathComponent(Self.encryptedPayloadFileName), options: .atomic)
            let manifestData = try MobileJSON.encoder.encode(manifest)
            try manifestData.write(to: temporary.appendingPathComponent(Self.manifestFileName), options: .atomic)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw MobilePackageError.destinationExists
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch let error as MobilePackageError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                throw MobilePackageError.destinationExists
            }
            throw MobilePackageError.stagingFailed
        }
    }

    public func importPreview(
        from source: URL,
        wrapping: MobilePackageKeyWrapping
    ) throws -> MobilePackageImportPreview {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { throw MobilePackageError.sourceNotFound }
        guard (try? fileManager.contentsOfDirectory(atPath: source.path))
            .map(Set.init) == Set([Self.manifestFileName, Self.encryptedPayloadFileName]) else {
            throw MobilePackageError.malformedPackage
        }
        guard fileManager.fileExists(atPath: source.appendingPathComponent(Self.manifestFileName).path),
              fileManager.fileExists(atPath: source.appendingPathComponent(Self.encryptedPayloadFileName).path) else {
            throw MobilePackageError.malformedPackage
        }

        let manifestURL = source.appendingPathComponent(Self.manifestFileName)
        guard Self.isRegularFile(manifestURL, fileManager: fileManager),
              Self.isRegularFile(source.appendingPathComponent(Self.encryptedPayloadFileName), fileManager: fileManager) else {
            throw MobilePackageError.malformedPackage
        }
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw MobilePackageError.malformedPackage
        }
        try Self.validateManifestJSON(manifestData)
        let manifest: MobilePackageManifest
        do {
            manifest = try MobileJSON.decoder.decode(MobilePackageManifest.self, from: manifestData)
        } catch {
            throw MobilePackageError.invalidManifest
        }
        try Self.validateManifest(manifest)
        guard !consumedPackageIDs.contains(manifest.packageID), stagedImports[manifest.packageID] == nil else {
            throw MobilePackageError.duplicatePackageID
        }

        let payloadURL = source.appendingPathComponent(Self.encryptedPayloadFileName)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: payloadURL.path)
        } catch {
            throw MobilePackageError.malformedPackage
        }
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value == manifest.encryptedByteCount else {
            throw MobilePackageError.manifestHashMismatch
        }
        let payloadData: Data
        do {
            payloadData = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
        } catch {
            throw MobilePackageError.malformedPackage
        }
        guard Int64(payloadData.count) == manifest.encryptedByteCount,
              MobilePackageCrypto.sha256Hex(payloadData) == manifest.ciphertextSHA256 else {
            throw MobilePackageError.manifestHashMismatch
        }

        let wrappedData: Data
        guard let wrappedBase64 = manifest.wrappedContentKeyBase64,
              let decodedWrapped = Data(base64Encoded: wrappedBase64),
              !decodedWrapped.isEmpty else {
            throw MobilePackageError.invalidManifest
        }
        wrappedData = decodedWrapped
        let contentKey: SymmetricKey
        do {
            contentKey = try wrapping.unwrap(wrappedData)
        } catch let error as MobilePackageError {
            throw error
        } catch {
            throw MobilePackageError.authenticationFailed
        }
        let sealed = try MobilePackageCrypto.payload(fromCombinedBytes: payloadData)
        let plaintext = try MobilePackageCrypto.open(sealed, using: contentKey)
        guard plaintext.count <= Int(Self.maximumEncryptedByteCount) else {
            throw MobilePackageError.invalidEnvelope
        }
        let envelope: MobilePackageEnvelope
        do {
            envelope = try MobileJSON.decoder.decode(MobilePackageEnvelope.self, from: plaintext)
        } catch {
            throw MobilePackageError.invalidEnvelope
        }
        try Self.validateEnvelope(envelope)

        let summary = Self.summary(for: envelope.snapshot)
        let preview = MobilePackageImportPreview(
            packageID: manifest.packageID,
            snapshotSummary: summary,
            incomingChanges: envelope.changes,
            encryptedByteCount: manifest.encryptedByteCount
        )
        stagedImports[manifest.packageID] = StagedImport(envelope: envelope, preview: preview)
        return preview
    }

    public func commitImport(packageID: UUID) throws -> MobilePackageEnvelope {
        guard let staged = stagedImports.removeValue(forKey: packageID) else {
            throw MobilePackageError.duplicatePackageID
        }
        consumedPackageIDs.insert(packageID)
        return staged.envelope
    }

    private static func validateManifestJSON(_ data: Data) throws {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw MobilePackageError.invalidManifest }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["formatVersion", "packageID", "createdAt", "encryptedByteCount", "ciphertextSHA256", "keyMode", "wrappedContentKeyBase64"] else {
            throw MobilePackageError.invalidManifest
        }
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeRegular
    }

    private static func validateManifest(_ manifest: MobilePackageManifest) throws {
        guard manifest.formatVersion > 0 else { throw MobilePackageError.invalidManifest }
        guard manifest.formatVersion <= currentFormatVersion else { throw MobilePackageError.unsupportedFormatVersion }
        guard manifest.encryptedByteCount >= Int64(MobilePackageCrypto.nonceByteCount + MobilePackageCrypto.tagByteCount),
              manifest.encryptedByteCount <= maximumEncryptedByteCount,
              manifest.createdAt.timeIntervalSince1970.isFinite,
              manifest.ciphertextSHA256.count == 64,
              manifest.ciphertextSHA256.allSatisfy({ $0.isNumber || ($0 >= "a" && $0 <= "f") || ($0 >= "A" && $0 <= "F") }),
              manifest.wrappedContentKeyBase64.map({ !$0.isEmpty && $0.count <= 4096 }) == true else {
            throw MobilePackageError.invalidManifest
        }
    }

    private static func validateEnvelope(_ envelope: MobilePackageEnvelope) throws {
        guard envelope.changes.count <= maximumCollectionCount,
              envelope.acknowledgedChangeIDs.count <= maximumCollectionCount,
              Set(envelope.acknowledgedChangeIDs).count == envelope.acknowledgedChangeIDs.count else {
            throw MobilePackageError.invalidEnvelope
        }
        if let snapshot = envelope.snapshot {
            guard snapshot.schemaVersion > 0, snapshot.schemaVersion <= MobileLibrarySnapshot.currentSchemaVersion,
                  snapshot.revision >= 0,
                  snapshot.projects.count <= maximumCollectionCount,
                  snapshot.nights.count <= maximumCollectionCount,
                  snapshot.captures.count <= maximumCollectionCount,
                  snapshot.briefings.count <= maximumCollectionCount,
                  snapshot.notes.count <= maximumCollectionCount else {
                throw MobilePackageError.unsupportedSchemaVersion
            }
        }
        var changeIDs = Set<UUID>()
        for change in envelope.changes {
            switch change {
            case .checklistCompletion(let value):
                guard changeIDs.insert(value.changeID).inserted else { throw MobilePackageError.invalidEnvelope }
                guard value.baseRevision >= 0, value.itemID.count <= maximumStringLength else { throw MobilePackageError.invalidEnvelope }
            case .noteRevision(let value):
                guard changeIDs.insert(value.changeID).inserted else { throw MobilePackageError.invalidEnvelope }
                guard value.baseRevision >= 0,
                      value.noteID.count <= maximumStringLength,
                      value.ownerID.count <= maximumStringLength,
                      value.text.count <= maximumStringLength else { throw MobilePackageError.invalidEnvelope }
            }
        }
    }

    private static func summary(for snapshot: MobileLibrarySnapshot?) -> MobileSnapshotSummary {
        guard let snapshot else {
            return MobileSnapshotSummary(projectCount: 0, nightCount: 0, captureCount: 0, briefingCount: 0, noteCount: 0)
        }
        return MobileSnapshotSummary(
            projectCount: snapshot.projects.count,
            nightCount: snapshot.nights.count,
            captureCount: snapshot.captures.count,
            briefingCount: snapshot.briefings.count,
            noteCount: snapshot.notes.count
        )
    }
}
