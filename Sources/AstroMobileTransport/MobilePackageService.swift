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
        guard Int64(plaintext.count) <= Self.maximumEncryptedByteCount else {
            throw MobilePackageError.invalidEnvelope
        }
        try Self.preflightJSON(plaintext)
        let aad = try Self.manifestAAD(
            formatVersion: Self.currentFormatVersion,
            packageID: packageID,
            createdAt: createdAt,
            keyMode: keyMode
        )
        let sealed = try MobilePackageCrypto.seal(plaintext, using: contentKey, authenticating: aad)
        let combined = MobilePackageCrypto.combinedBytes(sealed)
        guard Int64(combined.count) <= Self.maximumEncryptedByteCount else {
            throw MobilePackageError.invalidEnvelope
        }
        let wrappedKey = try wrapping.wrap(contentKey)
        guard !wrappedKey.isEmpty, wrappedKey.count <= 4096 else { throw MobilePackageError.invalidKey }

        let manifest = MobilePackageManifest(
            formatVersion: Self.currentFormatVersion,
            packageID: packageID,
            createdAt: createdAt,
            encryptedByteCount: Int64(combined.count),
            ciphertextSHA256: MobilePackageCrypto.sha256Hex(combined),
            keyMode: keyMode,
            wrappedContentKeyBase64: wrappedKey.base64EncodedString()
        )

        let manifestData = try MobileJSON.encoder.encode(manifest)
        guard manifestData.count <= Self.maximumManifestByteCount else {
            throw MobilePackageError.invalidManifest
        }

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
            try manifestData.write(to: temporary.appendingPathComponent(Self.manifestFileName), options: .atomic)
            guard Self.sameStableIdentity(temporaryIdentity, Self.identity(of: temporary, fileManager: fileManager)) else {
                throw MobilePackageError.stagingFailed
            }
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

        let directoryFD = source.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { throw MobilePackageError.malformedPackage }
        defer { Darwin.close(directoryFD) }

        let manifestData: Data
        do {
            guard Self.isRegular(at: directoryFD, name: Self.manifestFileName) else {
                throw MobilePackageError.malformedPackage
            }
            guard let size = Self.fileSize(at: directoryFD, name: Self.manifestFileName), size <= Self.maximumManifestByteCount else {
                throw MobilePackageError.invalidManifest
            }
            manifestData = try Self.readRegularFile(at: directoryFD, name: Self.manifestFileName, maximumByteCount: Int64(Self.maximumManifestByteCount))
        } catch {
            if let error = error as? MobilePackageError { throw error }
            throw MobilePackageError.malformedPackage
        }
        guard Self.sameStableIdentity(sourceIdentity, Self.identity(of: source, fileManager: fileManager)) else { throw MobilePackageError.malformedPackage }
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

        do {
            guard Self.isRegular(at: directoryFD, name: Self.encryptedPayloadFileName) else {
                throw MobilePackageError.malformedPackage
            }
            guard let fileSize = Self.fileSize(at: directoryFD, name: Self.encryptedPayloadFileName),
                  fileSize == manifest.encryptedByteCount,
                  fileSize <= Self.maximumEncryptedByteCount else {
            throw MobilePackageError.manifestHashMismatch
            }
        } catch let error as MobilePackageError {
            throw error
        } catch {
            throw MobilePackageError.manifestHashMismatch
        }
        let payloadData = try Self.readRegularFile(at: directoryFD, name: Self.encryptedPayloadFileName, maximumByteCount: Self.maximumEncryptedByteCount)
        guard Self.sameStableIdentity(sourceIdentity, Self.identity(of: source, fileManager: fileManager)) else { throw MobilePackageError.malformedPackage }
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
        try preflightJSON(data)
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
        guard let libraryID = object["libraryID"] as? [String: Any] else { throw MobilePackageError.invalidEnvelope }
        try requireKeys(libraryID, ["rawValue"])
        guard let projects = object["projects"] as? [Any], let nights = object["nights"] as? [Any],
              let captures = object["captures"] as? [Any], let briefings = object["briefings"] as? [Any],
              let notes = object["notes"] as? [Any],
              [projects.count, nights.count, captures.count, briefings.count, notes.count].allSatisfy({ $0 <= maximumCollectionCount }) else { throw MobilePackageError.invalidEnvelope }
        for value in projects { try requireKeys(try objectValue(value), required: ["id", "displayName", "catalogID", "phase", "integrationSeconds"], allowedOptional: ["goalHours"]) }
        for value in nights { try requireKeys(try objectValue(value), ["id", "localDate", "timeZoneID"]) }
        for value in captures { try requireKeys(try objectValue(value), required: ["id", "projectID", "nightID", "displayName", "exposureSeconds", "integrationSeconds"], allowedOptional: ["filterName"]) }
        for value in briefings {
            let briefing = try objectValue(value)
            try requireKeys(briefing, required: ["id", "revision", "savedAt", "readiness", "targets", "checklist", "noteID"], allowedOptional: ["nightDate"])
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
                for item in items { try requireKeys(try objectValue(item), required: ["id", "title", "isCompleted", "baseRevision"], allowedOptional: ["explanation"]) }
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

    /// Lexically bounds untrusted JSON before Foundation builds an object graph.
    /// This deliberately rejects malformed input early and caps both nesting and
    /// token/node work for the phone importer.
    private static func preflightJSON(_ data: Data) throws {
        guard data.count <= Int(maximumEncryptedByteCount) else { throw MobilePackageError.invalidEnvelope }
        var scanner = JSONPreflightScanner(bytes: Array(data))
        try scanner.parse()
    }

    private struct JSONPreflightScanner {
        let bytes: [UInt8]
        var index = 0
        var depth = 0
        var nodeCount = 0

        mutating func parse() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw MobilePackageError.invalidEnvelope }
        }

        mutating private func parseValue() throws {
            skipWhitespace()
            guard index < bytes.count else { throw MobilePackageError.invalidEnvelope }
            nodeCount += 1
            guard nodeCount <= MobilePackageService.maximumTotalNestedRecords * 8 else { throw MobilePackageError.invalidEnvelope }
            switch bytes[index] {
            case 0x7B: try parseObject()
            case 0x5B: try parseArray()
            case 0x22: try parseString()
            case 0x74: try parseLiteral(Array("true".utf8))
            case 0x66: try parseLiteral(Array("false".utf8))
            case 0x6E: try parseLiteral(Array("null".utf8))
            case 0x2D, 0x30...0x39: try parseNumber()
            default: throw MobilePackageError.invalidEnvelope
            }
        }

        mutating private func parseObject() throws {
            try enterContainer()
            index += 1
            skipWhitespace()
            var count = 0
            if consume(0x7D) { leaveContainer(); return }
            while true {
                count += 1
                guard count <= 32 else { throw MobilePackageError.invalidEnvelope }
                guard index < bytes.count, bytes[index] == 0x22 else { throw MobilePackageError.invalidEnvelope }
                try parseString()
                skipWhitespace(); guard consume(0x3A) else { throw MobilePackageError.invalidEnvelope }
                try parseValue()
                skipWhitespace()
                if consume(0x7D) { leaveContainer(); return }
                guard consume(0x2C) else { throw MobilePackageError.invalidEnvelope }
                skipWhitespace()
            }
        }

        mutating private func parseArray() throws {
            try enterContainer()
            index += 1
            skipWhitespace()
            var count = 0
            if consume(0x5D) { leaveContainer(); return }
            while true {
                count += 1
                guard count <= MobilePackageService.maximumCollectionCount else { throw MobilePackageError.invalidEnvelope }
                try parseValue()
                skipWhitespace()
                if consume(0x5D) { leaveContainer(); return }
                guard consume(0x2C) else { throw MobilePackageError.invalidEnvelope }
                skipWhitespace()
            }
        }

        mutating private func parseString() throws {
            guard consume(0x22) else { throw MobilePackageError.invalidEnvelope }
            var byteCount = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 { index += 1; guard byteCount <= MobilePackageService.maximumStringByteCount else { throw MobilePackageError.invalidEnvelope }; return }
                if byte < 0x20 { throw MobilePackageError.invalidEnvelope }
                if byte == 0x5C {
                    index += 1
                    guard index < bytes.count else { throw MobilePackageError.invalidEnvelope }
                    switch bytes[index] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: byteCount += 1; index += 1
                    case 0x75:
                        guard index + 4 < bytes.count else { throw MobilePackageError.invalidEnvelope }
                        for offset in 1...4 { guard isHex(bytes[index + offset]) else { throw MobilePackageError.invalidEnvelope } }
                        byteCount += 1; index += 5
                    default: throw MobilePackageError.invalidEnvelope
                    }
                } else {
                    byteCount += 1; index += 1
                }
                guard byteCount <= MobilePackageService.maximumStringByteCount else { throw MobilePackageError.invalidEnvelope }
            }
            throw MobilePackageError.invalidEnvelope
        }

        mutating private func parseLiteral(_ literal: [UInt8]) throws {
            guard bytes[index..<min(bytes.count, index + literal.count)].elementsEqual(literal) else { throw MobilePackageError.invalidEnvelope }
            index += literal.count
        }

        mutating private func parseNumber() throws {
            let start = index
            if consume(0x2D) {}
            if consume(0x30) {
                if index < bytes.count, bytes[index] >= 0x30 && bytes[index] <= 0x39 { throw MobilePackageError.invalidEnvelope }
            } else {
                guard consumeDigits() else { throw MobilePackageError.invalidEnvelope }
            }
            if consume(0x2E) { guard consumeDigits() else { throw MobilePackageError.invalidEnvelope } }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1; if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) { index += 1 }; guard consumeDigits() else { throw MobilePackageError.invalidEnvelope }
            }
            guard index > start, index - start <= 128 else { throw MobilePackageError.invalidEnvelope }
        }

        mutating private func consumeDigits() -> Bool {
            let start = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            return index > start
        }

        mutating private func enterContainer() throws { depth += 1; guard depth <= MobilePackageService.maximumJSONDepth else { throw MobilePackageError.invalidEnvelope } }
        mutating private func leaveContainer() { depth -= 1 }
        mutating private func consume(_ value: UInt8) -> Bool { guard index < bytes.count, bytes[index] == value else { return false }; index += 1; return true }
        mutating private func skipWhitespace() { while index < bytes.count && (bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D) { index += 1 } }
        private func isHex(_ value: UInt8) -> Bool { (value >= 0x30 && value <= 0x39) || (value >= 0x41 && value <= 0x46) || (value >= 0x61 && value <= 0x66) }
    }

    private static func objectValue(_ value: Any) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw MobilePackageError.invalidEnvelope }
        return object
    }

    private static func requireKeys(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw MobilePackageError.invalidEnvelope }
    }

    private static func requireKeys(_ object: [String: Any], required: Set<String>, allowedOptional: Set<String>) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(allowedOptional)) else {
            throw MobilePackageError.invalidEnvelope
        }
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
                + snapshot.briefings.reduce(0) { $0 + $1.targets.count + $1.checklist.count + $1.checklist.reduce(0) { $0 + $1.items.count } }
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
            let briefingItems: [UUID: Set<String>] = Dictionary(uniqueKeysWithValues: snapshot.briefings.map { briefing in
                (briefing.id, Set(briefing.checklist.flatMap(\.items).map(\.id)))
            })
            let notesByID = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.id, $0) })
            for change in envelope.changes {
                switch change {
                case .checklistCompletion(let value):
                    guard briefingItems[value.briefingID]?.contains(value.itemID) == true else { throw MobilePackageError.invalidEnvelope }
                case .noteRevision(let value):
                    guard let note = notesByID[value.noteID], note.ownerID == value.ownerID, note.isEditableOnPhone else { throw MobilePackageError.invalidEnvelope }
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
            var briefingItemIDs = Set<String>()
            for section in briefing.checklist {
                guard validString(section.id), validString(section.title) else { throw MobilePackageError.invalidEnvelope }
                for item in section.items {
                    guard briefingItemIDs.insert(item.id).inserted,
                          validString(item.id), validString(item.title), item.explanation.map(validString) ?? true, item.baseRevision >= 0 else { throw MobilePackageError.invalidEnvelope }
                }
            }
        }
        let noteIDs = Set(snapshot.notes.map(\.id))
        guard noteIDs.count == snapshot.notes.count else { throw MobilePackageError.invalidEnvelope }
        for briefing in snapshot.briefings { guard noteIDs.contains(briefing.noteID) else { throw MobilePackageError.invalidEnvelope } }
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

    private static func fileSize(at directoryFD: Int32, name: String) -> Int64? {
        var status = stat()
        let result = name.withCString { Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { return nil }
        let mode = status.st_mode & S_IFMT
        guard mode == S_IFREG else { return nil }
        return Int64(status.st_size)
    }

    private static func isRegular(at directoryFD: Int32, name: String) -> Bool {
        var status = stat()
        let result = name.withCString { Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW) }
        return result == 0 && status.st_mode & S_IFMT == S_IFREG
    }

    private static func readRegularFile(at directoryFD: Int32, name: String, maximumByteCount: Int64) throws -> Data {
        let descriptor = name.withCString { Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw MobilePackageError.malformedPackage }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              Int64(before.st_size) <= maximumByteCount,
              before.st_size <= Int64(Int.max) else {
            throw MobilePackageError.malformedPackage
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            guard count > 0 else { throw MobilePackageError.malformedPackage }
            offset += count
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_mode & S_IFMT == S_IFREG,
              after.st_nlink == 1,
              after.st_size == before.st_size else {
            throw MobilePackageError.malformedPackage
        }
        return Data(bytes)
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let identity = identity(of: url, fileManager: fileManager) else { return false }
        return identity.type == .typeDirectory
    }

    private static func removeTemporaryIfOwned(_ url: URL, identity expectedIdentity: FileIdentity?, fileManager: FileManager) {
        guard let expectedIdentity else { return }
        let parent = url.deletingLastPathComponent()
        let parentFD = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard parentFD >= 0 else { return }
        defer { Darwin.close(parentFD) }
        let childFD = url.lastPathComponent.withCString { Darwin.openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard childFD >= 0 else { return }
        defer { Darwin.close(childFD) }
        var status = stat()
        guard Darwin.fstat(childFD, &status) == 0,
              status.st_dev == Int32(truncatingIfNeeded: expectedIdentity.device),
              status.st_ino == expectedIdentity.inode,
              status.st_mode & S_IFMT == S_IFDIR else { return }
        for child in [Self.manifestFileName, Self.encryptedPayloadFileName] {
            _ = child.withCString { Darwin.unlinkat(childFD, $0, 0) }
        }
        _ = url.lastPathComponent.withCString { Darwin.unlinkat(parentFD, $0, AT_REMOVEDIR) }
    }

    private static func sameStableIdentity(_ lhs: FileIdentity?, _ rhs: FileIdentity?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.type == rhs.type
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
