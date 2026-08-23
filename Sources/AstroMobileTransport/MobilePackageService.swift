import CryptoKit
import Darwin
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

    /// Deliberately conservative for an offline iPhone package. The payload is
    /// metadata-only, not an image transport, so a large package is rejected.
    public static let maximumEncryptedByteCount: Int64 = 16 * 1024 * 1024
    public static let maximumManifestByteCount = 64 * 1024
    public static let maximumCollectionCount = 10_000
    public static let maximumTotalNestedRecords = 50_000
    public static let maximumStringByteCount = 256 * 1024
    public static let maximumJSONDepth = 32
    public static let maximumStagedImportCount = 8
    public static let maximumStagedImportBytes: Int64 = 32 * 1024 * 1024

    private struct AuthenticatedPayload: Codable {
        let packageID: UUID
        let envelope: MobilePackageEnvelope
    }

    private struct ManifestAADHeader: Codable {
        let formatVersion: Int
        let packageID: UUID
        let createdAt: Date
        let keyMode: MobilePackageKeyMode
    }

    private struct StagedImport: Sendable {
        let envelope: MobilePackageEnvelope
        let preview: MobilePackageImportPreview
    }

    private var stagedImports: [UUID: StagedImport] = [:]
    private var consumedPackageIDs: Set<UUID> = []
    private var stagedImportBytes: Int64 = 0

    public init() {}

    public func export(
        _ envelope: MobilePackageEnvelope,
        to destination: URL,
        wrapping: MobilePackageKeyWrapping
    ) throws {
        try Self.validateEnvelope(envelope)
        let packageID = UUID()
        let keyMode: MobilePackageKeyMode = wrapping is OneTimePackageKey ? .oneTimeQR : .pairedDevice
        let createdAt = Date()
        let contentKey = SymmetricKey(size: .bits256)
        let plaintext = try MobileJSON.encoder.encode(AuthenticatedPayload(packageID: packageID, envelope: envelope))
        let aad = try Self.manifestAAD(
            formatVersion: Self.currentFormatVersion,
            packageID: packageID,
            createdAt: createdAt,
            keyMode: keyMode
        )
        let sealed = try MobilePackageCrypto.seal(plaintext, using: contentKey, authenticating: aad)
        let combined = MobilePackageCrypto.combinedBytes(sealed)
        let wrappedKey = try wrapping.wrap(contentKey)
        guard !wrappedKey.isEmpty else { throw MobilePackageError.invalidKey }

        let manifest = MobilePackageManifest(
            formatVersion: Self.currentFormatVersion,
            packageID: packageID,
            createdAt: createdAt,
            encryptedByteCount: Int64(combined.count),
            ciphertextSHA256: MobilePackageCrypto.sha256Hex(combined),
            keyMode: keyMode,
            wrappedContentKeyBase64: wrappedKey.base64EncodedString()
        )

        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        var temporaryIdentity: FileIdentity?
        do {
            guard fileManager.fileExists(atPath: parent.path) else {
                throw MobilePackageError.stagingFailed
            }
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
            temporaryIdentity = Self.identity(of: temporary, fileManager: fileManager)
            guard temporaryIdentity != nil else { throw MobilePackageError.stagingFailed }
            try combined.write(to: temporary.appendingPathComponent(Self.encryptedPayloadFileName), options: .atomic)
            let manifestData = try MobileJSON.encoder.encode(manifest)
            try manifestData.write(to: temporary.appendingPathComponent(Self.manifestFileName), options: .atomic)
            try Self.publishExclusively(from: temporary, to: destination)
        } catch let error as MobilePackageError {
            Self.removeTemporaryIfOwned(temporary, identity: temporaryIdentity, fileManager: fileManager)
            throw error
        } catch {
            Self.removeTemporaryIfOwned(temporary, identity: temporaryIdentity, fileManager: fileManager)
            if (error as NSError).code == EEXIST || fileManager.fileExists(atPath: destination.path) { throw MobilePackageError.destinationExists }
            throw MobilePackageError.stagingFailed
        }
    }

    public func importPreview(
        from source: URL,
        wrapping: MobilePackageKeyWrapping
    ) throws -> MobilePackageImportPreview {
        let fileManager = FileManager.default
        guard Self.isDirectory(source, fileManager: fileManager) else {
            if fileManager.fileExists(atPath: source.path) { throw MobilePackageError.malformedPackage }
            throw MobilePackageError.sourceNotFound
        }
        let sourceIdentity = Self.identity(of: source, fileManager: fileManager)
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
        let manifestIdentityBeforeRead = Self.identity(of: manifestURL, fileManager: fileManager)
        do {
            guard let size = Self.fileSize(of: manifestURL, fileManager: fileManager), size <= Self.maximumManifestByteCount else {
                throw MobilePackageError.invalidManifest
            }
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            if let error = error as? MobilePackageError { throw error }
            throw MobilePackageError.malformedPackage
        }
        guard sourceIdentity == Self.identity(of: source, fileManager: fileManager) else { throw MobilePackageError.malformedPackage }
        guard let manifestIdentityBeforeRead,
              manifestIdentityBeforeRead.type == .typeRegular,
              manifestIdentityBeforeRead == Self.identity(of: manifestURL, fileManager: fileManager) else { throw MobilePackageError.malformedPackage }
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
        let payloadIdentityBeforeRead = Self.identity(of: payloadURL, fileManager: fileManager)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: payloadURL.path)
        } catch {
            throw MobilePackageError.malformedPackage
        }
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value == manifest.encryptedByteCount,
              fileSize.int64Value <= Self.maximumEncryptedByteCount else {
            throw MobilePackageError.manifestHashMismatch
        }
        let payloadData: Data
        do {
            payloadData = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
        } catch {
            throw MobilePackageError.malformedPackage
        }
        guard sourceIdentity == Self.identity(of: source, fileManager: fileManager),
              payloadIdentityBeforeRead?.type == .typeRegular,
              payloadIdentityBeforeRead == Self.identity(of: payloadURL, fileManager: fileManager) else { throw MobilePackageError.malformedPackage }
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
        let aad = try Self.manifestAAD(
            formatVersion: manifest.formatVersion,
            packageID: manifest.packageID,
            createdAt: manifest.createdAt,
            keyMode: manifest.keyMode
        )
        let plaintext = try MobilePackageCrypto.openCombined(payloadData, using: contentKey, authenticating: aad)
        guard plaintext.count <= Int(Self.maximumEncryptedByteCount) else {
            throw MobilePackageError.invalidEnvelope
        }
        try Self.validateEnvelopeJSON(plaintext)
        let authenticatedPayload: AuthenticatedPayload
        do {
            authenticatedPayload = try MobileJSON.decoder.decode(AuthenticatedPayload.self, from: plaintext)
        } catch {
            throw MobilePackageError.invalidEnvelope
        }
        guard authenticatedPayload.packageID == manifest.packageID else { throw MobilePackageError.packageIDMismatch }
        let envelope = authenticatedPayload.envelope
        try Self.validateEnvelope(envelope)

        let summary = Self.summary(for: envelope.snapshot)
        let preview = MobilePackageImportPreview(
            packageID: manifest.packageID,
            snapshotSummary: summary,
            incomingChanges: envelope.changes,
            encryptedByteCount: manifest.encryptedByteCount
        )
        guard stagedImports.count < Self.maximumStagedImportCount,
              stagedImportBytes <= Self.maximumStagedImportBytes - manifest.encryptedByteCount else {
            throw MobilePackageError.stagingFailed
        }
        stagedImports[manifest.packageID] = StagedImport(envelope: envelope, preview: preview)
        stagedImportBytes += manifest.encryptedByteCount
        return preview
    }

    public func commitImport(packageID: UUID) throws -> MobilePackageEnvelope {
        guard let staged = stagedImports.removeValue(forKey: packageID) else {
            throw MobilePackageError.duplicatePackageID
        }
        stagedImportBytes = max(0, stagedImportBytes - staged.preview.encryptedByteCount)
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
        identity(of: url, fileManager: fileManager)?.type == .typeRegular
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

    private static func manifestAAD(
        formatVersion: Int,
        packageID: UUID,
        createdAt: Date,
        keyMode: MobilePackageKeyMode
    ) throws -> Data {
        try MobileJSON.encoder.encode(ManifestAADHeader(
            formatVersion: formatVersion,
            packageID: packageID,
            createdAt: createdAt,
            keyMode: keyMode
        ))
    }

    private static func validateEnvelopeJSON(_ data: Data) throws {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw MobilePackageError.invalidEnvelope }
        var nodeCount = 0
        try validateJSONNode(object, depth: 0, nodeCount: &nodeCount)
        guard let payload = object as? [String: Any] else { throw MobilePackageError.invalidEnvelope }
        try requireKeys(payload, ["packageID", "envelope"])
        try validateEnvelopeObject(payload["envelope"])
    }

    private static func validateEnvelopeObject(_ value: Any?) throws {
        guard let object = value as? [String: Any] else { throw MobilePackageError.invalidEnvelope }
        let baseKeys: Set<String> = ["changes", "acknowledgedChangeIDs"]
        guard Set(object.keys) == baseKeys || Set(object.keys) == baseKeys.union(["snapshot"]) else { throw MobilePackageError.invalidEnvelope }
        if let snapshot = object["snapshot"], !(snapshot is NSNull) { try validateSnapshotObject(snapshot) }
        guard let changes = object["changes"] as? [Any], changes.count <= maximumCollectionCount,
              let acknowledged = object["acknowledgedChangeIDs"] as? [Any], acknowledged.count <= maximumCollectionCount else {
            throw MobilePackageError.invalidEnvelope
        }
        for value in acknowledged { guard value is String else { throw MobilePackageError.invalidEnvelope } }
        for value in changes {
            guard let change = value as? [String: Any] else { throw MobilePackageError.invalidEnvelope }
            try requireKeys(change, ["kind", "payload"])
            guard let kind = change["kind"] as? String, let payload = change["payload"] as? [String: Any] else { throw MobilePackageError.invalidEnvelope }
            switch kind {
            case MobileChangeKind.checklistCompletion.rawValue:
                try requireKeys(payload, ["changeID", "deviceID", "briefingID", "itemID", "baseRevision", "isCompleted", "createdAt"])
            case MobileChangeKind.noteRevision.rawValue:
                try requireKeys(payload, ["changeID", "deviceID", "noteID", "ownerID", "baseRevision", "text", "createdAt"])
            default:
                throw MobilePackageError.invalidEnvelope
            }
        }
    }

    private static func validateSnapshotObject(_ value: Any) throws {
        guard let object = value as? [String: Any] else { throw MobilePackageError.invalidEnvelope }
        try requireKeys(object, ["schemaVersion", "libraryID", "snapshotID", "revision", "createdAt", "projects", "nights", "captures", "briefings", "notes"])
        guard let projects = object["projects"] as? [Any], let nights = object["nights"] as? [Any],
              let captures = object["captures"] as? [Any], let briefings = object["briefings"] as? [Any],
              let notes = object["notes"] as? [Any],
              [projects.count, nights.count, captures.count, briefings.count, notes.count].allSatisfy({ $0 <= maximumCollectionCount }) else { throw MobilePackageError.invalidEnvelope }
        for value in projects { try requireKeys(try objectValue(value), ["id", "displayName", "catalogID", "phase", "integrationSeconds", "goalHours"]) }
        for value in nights { try requireKeys(try objectValue(value), ["id", "localDate", "timeZoneID"]) }
        for value in captures { try requireKeys(try objectValue(value), ["id", "projectID", "nightID", "displayName", "filterName", "exposureSeconds", "integrationSeconds"]) }
        for value in briefings {
            let briefing = try objectValue(value)
            try requireKeys(briefing, ["id", "revision", "savedAt", "nightDate", "readiness", "targets", "checklist", "noteID"])
            guard let targets = briefing["targets"] as? [Any], let checklist = briefing["checklist"] as? [Any], targets.count <= maximumCollectionCount, checklist.count <= maximumCollectionCount else { throw MobilePackageError.invalidEnvelope }
            for target in targets {
                let targetObject = try objectValue(target)
                try requireKeys(targetObject, ["id", "name", "role", "start", "end", "warnings"])
                guard let warnings = targetObject["warnings"] as? [Any], warnings.count <= maximumCollectionCount else { throw MobilePackageError.invalidEnvelope }
            }
            for section in checklist {
                let sectionObject = try objectValue(section)
                try requireKeys(sectionObject, ["id", "title", "items"])
                guard let items = sectionObject["items"] as? [Any], items.count <= maximumCollectionCount else { throw MobilePackageError.invalidEnvelope }
                for item in items { try requireKeys(try objectValue(item), ["id", "title", "explanation", "isCompleted", "baseRevision"]) }
            }
        }
        for value in notes { try requireKeys(try objectValue(value), ["id", "scope", "ownerID", "text", "baseRevision", "updatedAt", "isEditableOnPhone"]) }
    }

    private static func validateJSONNode(_ value: Any, depth: Int, nodeCount: inout Int) throws {
        guard depth <= maximumJSONDepth else { throw MobilePackageError.invalidEnvelope }
        nodeCount += 1
        guard nodeCount <= maximumTotalNestedRecords * 4 else { throw MobilePackageError.invalidEnvelope }
        if let string = value as? String {
            guard string.utf8.count <= maximumStringByteCount else { throw MobilePackageError.invalidEnvelope }
        } else if let array = value as? [Any] {
            guard array.count <= maximumCollectionCount else { throw MobilePackageError.invalidEnvelope }
            for child in array { try validateJSONNode(child, depth: depth + 1, nodeCount: &nodeCount) }
        } else if let object = value as? [String: Any] {
            guard object.count <= 32 else { throw MobilePackageError.invalidEnvelope }
            for (key, child) in object {
                guard key.utf8.count <= 128 else { throw MobilePackageError.invalidEnvelope }
                try validateJSONNode(child, depth: depth + 1, nodeCount: &nodeCount)
            }
        } else if let number = value as? NSNumber {
            guard number.doubleValue.isFinite else { throw MobilePackageError.invalidEnvelope }
        } else if value is NSNull {
            return
        } else {
            throw MobilePackageError.invalidEnvelope
        }
    }

    private static func objectValue(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw MobilePackageError.invalidEnvelope }
        return object
    }

    private static func requireKeys(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw MobilePackageError.invalidEnvelope }
    }

    private static func validateEnvelope(_ envelope: MobilePackageEnvelope) throws {
        guard envelope.changes.count <= maximumCollectionCount,
              envelope.acknowledgedChangeIDs.count <= maximumCollectionCount,
              Set(envelope.acknowledgedChangeIDs).count == envelope.acknowledgedChangeIDs.count else {
            throw MobilePackageError.invalidEnvelope
        }
        let snapshot = envelope.snapshot
        if let snapshot {
            guard snapshot.schemaVersion > 0, snapshot.schemaVersion <= MobileLibrarySnapshot.currentSchemaVersion,
                  snapshot.revision >= 0,
                  snapshot.projects.count <= maximumCollectionCount,
                  snapshot.nights.count <= maximumCollectionCount,
                  snapshot.captures.count <= maximumCollectionCount,
                  snapshot.briefings.count <= maximumCollectionCount,
                  snapshot.notes.count <= maximumCollectionCount else {
                throw MobilePackageError.unsupportedSchemaVersion
            }
            let totalRecords = snapshot.projects.count + snapshot.nights.count + snapshot.captures.count + snapshot.briefings.count + snapshot.notes.count
            guard totalRecords <= maximumTotalNestedRecords else { throw MobilePackageError.invalidEnvelope }
            try validateSnapshotDomain(snapshot)
        }
        var changeIDs = Set<UUID>()
        for change in envelope.changes {
            switch change {
            case .checklistCompletion(let value):
                guard changeIDs.insert(value.changeID).inserted else { throw MobilePackageError.invalidEnvelope }
                guard value.baseRevision >= 0, validString(value.itemID), value.createdAt.timeIntervalSince1970.isFinite else { throw MobilePackageError.invalidEnvelope }
            case .noteRevision(let value):
                guard changeIDs.insert(value.changeID).inserted else { throw MobilePackageError.invalidEnvelope }
                guard value.baseRevision >= 0,
                      validString(value.noteID), validString(value.ownerID), validString(value.text),
                      value.createdAt.timeIntervalSince1970.isFinite else { throw MobilePackageError.invalidEnvelope }
            }
        }
        if let snapshot {
            let briefingIDs = Set(snapshot.briefings.map(\.id))
            let noteIDs = Set(snapshot.notes.map(\.id))
            for change in envelope.changes {
                switch change {
                case .checklistCompletion(let value):
                    guard briefingIDs.contains(value.briefingID), snapshot.briefings.first(where: { $0.id == value.briefingID })?.checklist.contains(where: { $0.items.contains(where: { $0.id == value.itemID }) }) == true else { throw MobilePackageError.invalidEnvelope }
                case .noteRevision(let value):
                    guard noteIDs.contains(value.noteID) else { throw MobilePackageError.invalidEnvelope }
                }
            }
        }
    }

    private static func validateSnapshotDomain(_ snapshot: MobileLibrarySnapshot) throws {
        guard snapshot.createdAt.timeIntervalSince1970.isFinite else { throw MobilePackageError.invalidEnvelope }
        let projectIDs = Set(snapshot.projects.map(\.id))
        let nightIDs = Set(snapshot.nights.map(\.id))
        guard projectIDs.count == snapshot.projects.count, nightIDs.count == snapshot.nights.count else { throw MobilePackageError.invalidEnvelope }
        for project in snapshot.projects {
            guard validString(project.displayName), validString(project.catalogID), validString(project.phase), project.integrationSeconds.isFinite, project.integrationSeconds >= 0,
                  project.goalHours.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw MobilePackageError.invalidEnvelope }
        }
        for night in snapshot.nights { guard validString(night.localDate), validString(night.timeZoneID) else { throw MobilePackageError.invalidEnvelope } }
        let captureIDs = Set(snapshot.captures.map(\.id))
        guard captureIDs.count == snapshot.captures.count else { throw MobilePackageError.invalidEnvelope }
        for capture in snapshot.captures {
            guard projectIDs.contains(capture.projectID), nightIDs.contains(capture.nightID), validString(capture.displayName), capture.filterName.map(validString) ?? true,
                  capture.exposureSeconds.isFinite, capture.exposureSeconds >= 0, capture.integrationSeconds.isFinite, capture.integrationSeconds >= 0 else { throw MobilePackageError.invalidEnvelope }
        }
        let briefingIDs = Set(snapshot.briefings.map(\.id))
        guard briefingIDs.count == snapshot.briefings.count else { throw MobilePackageError.invalidEnvelope }
        for briefing in snapshot.briefings {
            guard briefing.revision >= 0, briefing.savedAt.timeIntervalSince1970.isFinite, briefing.nightDate?.timeIntervalSince1970.isFinite ?? true,
                  validString(briefing.readiness), validString(briefing.noteID) else { throw MobilePackageError.invalidEnvelope }
            let targetIDs = Set(briefing.targets.map(\.id))
            guard targetIDs.count == briefing.targets.count else { throw MobilePackageError.invalidEnvelope }
            for target in briefing.targets { guard validString(target.name), validString(target.role), target.start.timeIntervalSince1970.isFinite, target.end.timeIntervalSince1970.isFinite, target.end >= target.start, target.warnings.allSatisfy(validString) else { throw MobilePackageError.invalidEnvelope } }
            let sectionIDs = Set(briefing.checklist.map(\.id))
            guard sectionIDs.count == briefing.checklist.count else { throw MobilePackageError.invalidEnvelope }
            for section in briefing.checklist {
                guard validString(section.id), validString(section.title) else { throw MobilePackageError.invalidEnvelope }
                let itemIDs = Set(section.items.map(\.id))
                guard itemIDs.count == section.items.count else { throw MobilePackageError.invalidEnvelope }
                for item in section.items { guard validString(item.id), validString(item.title), item.explanation.map(validString) ?? true, item.baseRevision >= 0 else { throw MobilePackageError.invalidEnvelope } }
            }
        }
        let noteIDs = Set(snapshot.notes.map(\.id))
        guard noteIDs.count == snapshot.notes.count else { throw MobilePackageError.invalidEnvelope }
        for note in snapshot.notes { guard validString(note.id), validString(note.ownerID), validString(note.text), note.baseRevision >= 0, note.updatedAt.timeIntervalSince1970.isFinite else { throw MobilePackageError.invalidEnvelope } }
    }

    private static func validString(_ value: String) -> Bool { value.utf8.count <= maximumStringByteCount }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let type: FileAttributeType
    }

    private static func identity(of url: URL, fileManager: FileManager) -> FileIdentity? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else { return nil }
        let mode = status.st_mode & S_IFMT
        let type: FileAttributeType
        switch mode {
        case S_IFDIR: type = .typeDirectory
        case S_IFREG: type = .typeRegular
        default: type = .typeSymbolicLink
        }
        return FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size), type: type)
    }

    private static func fileSize(of url: URL, fileManager: FileManager) -> Int64? {
        identity(of: url, fileManager: fileManager)?.size
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let identity = identity(of: url, fileManager: fileManager) else { return false }
        return identity.type == .typeDirectory
    }

    private static func removeTemporaryIfOwned(_ url: URL, identity expectedIdentity: FileIdentity?, fileManager: FileManager) {
        guard let expectedIdentity, let current = Self.identity(of: url, fileManager: fileManager), current == expectedIdentity else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func publishExclusively(from temporary: URL, to destination: URL) throws {
        let result = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw MobilePackageError.destinationExists }
            throw MobilePackageError.stagingFailed
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
