import CryptoKit
import Darwin
import Foundation
import AstroMobileDomain

protocol MobilePackageStagingDirectoryProvider: Sendable {
    func replacementDirectory(appropriateFor destination: URL) throws -> URL
}

private struct SystemStagingDirectoryProvider: MobilePackageStagingDirectoryProvider {
    func replacementDirectory(appropriateFor destination: URL) throws -> URL {
        // `itemReplacementDirectory` is an exporter-oriented API: its
        // relationship with a final URL is platform-dependent and SwiftUI
        // may already have materialized that URL before this service runs.
        // Anchor staging to the existing destination parent instead. The
        // secure mkdtemp/openat path below creates a private child on the
        // same volume without ever touching the final package name.
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        var info: Darwin.stat = .init()
        let result = parent.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw MobilePackageError.stagingFailed
        }
        return parent
    }
}

enum MobilePackageExportTestStep: Sendable {
    case afterProvisionalIdentity
    case beforeFirstFile
    case beforeSecondFile
    case beforePublication
    case afterRename
}

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
    public static let maximumEstimatedContentByteCount: Int64 = 8 * 1024 * 1024
    public static let maximumWrappedKeyByteCount = 4096
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
    private let stagingDirectoryProvider: any MobilePackageStagingDirectoryProvider
    private let testingExportStep: @Sendable (MobilePackageExportTestStep, URL) -> Void
    private let testingDirectoryDuplicate: @Sendable (Int32) -> Int32

    public init() {
        self.stagingDirectoryProvider = SystemStagingDirectoryProvider()
        self.testingExportStep = { _, _ in }
        self.testingDirectoryDuplicate = Darwin.dup
    }

    init(testingBeforePublication: @escaping @Sendable (URL) -> Void) {
        self.stagingDirectoryProvider = SystemStagingDirectoryProvider()
        self.testingExportStep = { step, url in if step == .beforePublication { testingBeforePublication(url) } }
        self.testingDirectoryDuplicate = Darwin.dup
    }

    init(
        stagingDirectoryProvider: any MobilePackageStagingDirectoryProvider,
        testingExportStep: @escaping @Sendable (MobilePackageExportTestStep, URL) -> Void = { _, _ in },
        testingDirectoryDuplicate: @escaping @Sendable (Int32) -> Int32 = Darwin.dup
    ) {
        self.stagingDirectoryProvider = stagingDirectoryProvider
        self.testingExportStep = testingExportStep
        self.testingDirectoryDuplicate = testingDirectoryDuplicate
    }

    public func export(
        _ envelope: MobilePackageEnvelope,
        to destination: URL,
        wrapping: MobilePackageKeyWrapping
    ) throws -> MobilePackageManifest {
        try Self.validateEnvelope(envelope, forExport: true)
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
        guard !wrappedKey.isEmpty, wrappedKey.count <= Self.maximumWrappedKeyByteCount else { throw MobilePackageError.invalidKey }

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

        let staging: PrivateStaging
        do {
            let replacementDirectory = try stagingDirectoryProvider.replacementDirectory(appropriateFor: destination)
            staging = try Self.createPrivateStaging(in: replacementDirectory, testingExportStep: testingExportStep)
        } catch let error as MobilePackageError {
            throw error
        } catch {
            throw MobilePackageError.stagingFailed
        }
        defer { staging.finish() }
        testingExportStep(.beforeFirstFile, staging.url)
        try Self.writeFile(at: staging.descriptor, name: Self.encryptedPayloadFileName, data: combined)
        testingExportStep(.beforeSecondFile, staging.url)
        try Self.writeFile(at: staging.descriptor, name: Self.manifestFileName, data: manifestData)
        guard Self.sameStableIdentity(staging.identity, Self.identity(ofFD: staging.descriptor)) else {
            throw MobilePackageError.stagingFailed
        }

        let parent = destination.deletingLastPathComponent()
        let parentFD = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard parentFD >= 0 else { throw MobilePackageError.stagingFailed }
        defer { Darwin.close(parentFD) }
        do {
            try Self.publishExclusively(
                parentFD: parentFD,
                destinationName: destination.lastPathComponent,
                staging: staging,
                testingExportStep: testingExportStep,
                destination: destination
            )
        } catch let error as MobilePackageError {
            throw error
        } catch {
            if (error as NSError).code == EEXIST { throw MobilePackageError.destinationExists }
            throw MobilePackageError.stagingFailed
        }
        return manifest
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
        let directoryFD = source.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { throw MobilePackageError.malformedPackage }
        defer { Darwin.close(directoryFD) }
        guard Self.sameStableIdentity(sourceIdentity, Self.identity(ofFD: directoryFD)),
              (try? Self.directoryEntries(directoryFD, duplicating: testingDirectoryDuplicate)) == Set([Self.manifestFileName, Self.encryptedPayloadFileName]) else {
            throw MobilePackageError.malformedPackage
        }

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
              !decodedWrapped.isEmpty,
              decodedWrapped.count <= Self.maximumWrappedKeyByteCount,
              decodedWrapped.base64EncodedString() == wrappedBase64 else {
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

    /// Drops authenticated preview material staged only for review. The
    /// package remains eligible for a later re-preview with the same key.
    public func discardImportPreview(packageID: UUID) {
        guard let staged = stagedImports.removeValue(forKey: packageID) else { return }
        stagedImportBytes = max(0, stagedImportBytes - staged.preview.encryptedByteCount)
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
              manifest.wrappedContentKeyBase64.map({ !$0.isEmpty && $0.count <= 8192 }) == true else {
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
    static func preflightJSONForTesting(_ data: Data) throws {
        try preflightJSON(data)
    }

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
                guard try parseString(maximumByteCount: 128) <= 128 else { throw MobilePackageError.invalidEnvelope }
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

        @discardableResult
        mutating private func parseString(maximumByteCount: Int = MobilePackageService.maximumStringByteCount) throws -> Int {
            guard consume(0x22) else { throw MobilePackageError.invalidEnvelope }
            var byteCount = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 { index += 1; guard byteCount <= maximumByteCount else { throw MobilePackageError.invalidEnvelope }; return byteCount }
                if byte < 0x20 { throw MobilePackageError.invalidEnvelope }
                if byte == 0x5C {
                    index += 1
                    guard index < bytes.count else { throw MobilePackageError.invalidEnvelope }
                    switch bytes[index] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: byteCount += 1; index += 1
                    case 0x75:
                        index -= 1
                        let first = try parseUnicodeEscape()
                        if first >= 0xD800 && first <= 0xDBFF {
                            guard index + 5 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else { throw MobilePackageError.invalidEnvelope }
                            let second = try parseUnicodeEscape()
                            guard second >= 0xDC00 && second <= 0xDFFF else { throw MobilePackageError.invalidEnvelope }
                            byteCount += 4
                        } else if first >= 0xDC00 && first <= 0xDFFF {
                            throw MobilePackageError.invalidEnvelope
                        } else {
                            byteCount += first <= 0x7F ? 1 : (first <= 0x7FF ? 2 : 3)
                        }
                    default: throw MobilePackageError.invalidEnvelope
                    }
                } else {
                    byteCount += try consumeUTF8Scalar()
                }
                guard byteCount <= maximumByteCount else { throw MobilePackageError.invalidEnvelope }
            }
            throw MobilePackageError.invalidEnvelope
        }

        mutating private func parseUnicodeEscape() throws -> Int {
            guard index < bytes.count, bytes[index] == 0x5C, index + 5 < bytes.count, bytes[index + 1] == 0x75 else { throw MobilePackageError.invalidEnvelope }
            var value = 0
            for offset in 2...5 { guard isHex(bytes[index + offset]) else { throw MobilePackageError.invalidEnvelope }; value = value * 16 + hexValue(bytes[index + offset]) }
            index += 6
            return value
        }

        mutating private func consumeUTF8Scalar() throws -> Int {
            let first = bytes[index]
            let length: Int
            let minimum: UInt32
            if first <= 0x7F { length = 1; minimum = 0 }
            else if first >= 0xC2 && first <= 0xDF { length = 2; minimum = 0x80 }
            else if first >= 0xE0 && first <= 0xEF { length = 3; minimum = 0x800 }
            else if first >= 0xF0 && first <= 0xF4 { length = 4; minimum = 0x10000 }
            else { throw MobilePackageError.invalidEnvelope }
            guard index + length <= bytes.count else { throw MobilePackageError.invalidEnvelope }
            var scalar = UInt32(first & (length == 1 ? 0x7F : length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07))
            if length > 1 {
                for offset in 1..<length { let continuation = bytes[index + offset]; guard continuation & 0xC0 == 0x80 else { throw MobilePackageError.invalidEnvelope }; scalar = (scalar << 6) | UInt32(continuation & 0x3F) }
            }
            guard scalar >= minimum, scalar <= 0x10FFFF, !(scalar >= 0xD800 && scalar <= 0xDFFF) else { throw MobilePackageError.invalidEnvelope }
            index += length
            return length
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
        private func hexValue(_ value: UInt8) -> Int { value >= 0x30 && value <= 0x39 ? Int(value - 0x30) : (value >= 0x41 && value <= 0x46 ? Int(value - 0x41) + 10 : Int(value - 0x61) + 10) }
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

    private static func validateEnvelope(_ envelope: MobilePackageEnvelope, forExport: Bool = false) throws {
        guard envelope.changes.count <= maximumCollectionCount,
              envelope.acknowledgedChangeIDs.count <= maximumCollectionCount,
              Set(envelope.acknowledgedChangeIDs).count == envelope.acknowledgedChangeIDs.count else {
            throw MobilePackageError.invalidEnvelope
        }
        if forExport { try validateExportEncodingBudget(envelope) }
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
        let notesByID = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.id, $0) })
        for briefing in snapshot.briefings {
            guard let note = notesByID[briefing.noteID], note.scope == .briefing, note.ownerID == briefing.id.uuidString else { throw MobilePackageError.invalidEnvelope }
        }
        for note in snapshot.notes { guard validString(note.id), validString(note.ownerID), validString(note.text), note.baseRevision >= 0, note.updatedAt.timeIntervalSince1970.isFinite else { throw MobilePackageError.invalidEnvelope } }
    }

    private static func validateExportEncodingBudget(_ envelope: MobilePackageEnvelope) throws {
        var budget = ExportEncodingBudget()
        try budget.addRecord()
        try budget.addRecord()
        try budget.addArray(envelope.acknowledgedChangeIDs.count)
        for id in envelope.acknowledgedChangeIDs { try budget.addString(id.uuidString) }
        try budget.addArray(envelope.changes.count)
        for change in envelope.changes {
            try budget.addRecord()
            switch change {
            case .checklistCompletion(let value):
                try budget.addString(value.changeID.uuidString); try budget.addString(value.deviceID.uuidString)
                try budget.addString(value.briefingID.uuidString); try budget.addString(value.itemID)
            case .noteRevision(let value):
                try budget.addString(value.changeID.uuidString); try budget.addString(value.deviceID.uuidString)
                try budget.addString(value.noteID); try budget.addString(value.ownerID); try budget.addString(value.text)
            }
        }
        guard let snapshot = envelope.snapshot else { return }
        try budget.addRecord()
        try budget.addString(snapshot.libraryID.rawValue.uuidString)
        try budget.addString(snapshot.snapshotID.uuidString)
        try budget.addArray(snapshot.projects.count)
        for project in snapshot.projects {
            try budget.addRecord(); try budget.addString(project.id.uuidString); try budget.addString(project.displayName)
            try budget.addString(project.catalogID); try budget.addString(project.phase)
        }
        try budget.addArray(snapshot.nights.count)
        for night in snapshot.nights {
            try budget.addRecord(); try budget.addString(night.id.uuidString); try budget.addString(night.localDate); try budget.addString(night.timeZoneID)
        }
        try budget.addArray(snapshot.captures.count)
        for capture in snapshot.captures {
            try budget.addRecord(); try budget.addString(capture.id.uuidString); try budget.addString(capture.projectID.uuidString)
            try budget.addString(capture.nightID.uuidString); try budget.addString(capture.displayName)
            if let value = capture.filterName { try budget.addString(value) }
        }
        try budget.addArray(snapshot.briefings.count)
        for briefing in snapshot.briefings {
            try budget.addRecord(); try budget.addString(briefing.id.uuidString); try budget.addString(briefing.readiness); try budget.addString(briefing.noteID)
            try budget.addArray(briefing.targets.count)
            for target in briefing.targets {
                try budget.addRecord(); try budget.addString(target.id.uuidString); try budget.addString(target.name); try budget.addString(target.role)
                try budget.addArray(target.warnings.count)
                for warning in target.warnings { try budget.addString(warning) }
            }
            try budget.addArray(briefing.checklist.count)
            for section in briefing.checklist {
                try budget.addRecord(); try budget.addString(section.id); try budget.addString(section.title)
                try budget.addArray(section.items.count)
                for item in section.items {
                    try budget.addRecord(); try budget.addString(item.id); try budget.addString(item.title)
                    if let explanation = item.explanation { try budget.addString(explanation) }
                }
            }
        }
        try budget.addArray(snapshot.notes.count)
        for note in snapshot.notes {
            try budget.addRecord(); try budget.addString(note.id); try budget.addString(note.scope.rawValue)
            try budget.addString(note.ownerID); try budget.addString(note.text)
        }
    }

    private struct ExportEncodingBudget {
        private var encodedByteCount: Int64 = 0
        private var elementCount: Int64 = 0

        mutating func addRecord() throws { try add(512) }

        mutating func addArray(_ count: Int) throws {
            guard count <= maximumCollectionCount else { throw MobilePackageError.invalidEnvelope }
            let count64 = Int64(count)
            let (nextElements, elementOverflow) = elementCount.addingReportingOverflow(count64)
            guard !elementOverflow, nextElements <= maximumTotalNestedRecords else { throw MobilePackageError.invalidEnvelope }
            elementCount = nextElements
            let (arrayBytes, byteOverflow) = count64.multipliedReportingOverflow(by: 16)
            guard !byteOverflow else { throw MobilePackageError.invalidEnvelope }
            try add(arrayBytes)
        }

        mutating func addString(_ value: String) throws {
            var escapedByteCount: Int64 = 2
            for byte in value.utf8 {
                let cost: Int64
                switch byte {
                case 0x00...0x1F: cost = 6
                case 0x22, 0x5C, 0x2F: cost = 2
                default: cost = 1
                }
                let (next, overflow) = escapedByteCount.addingReportingOverflow(cost)
                guard !overflow else { throw MobilePackageError.invalidEnvelope }
                escapedByteCount = next
            }
            try add(escapedByteCount)
        }

        private mutating func add(_ count: Int64) throws {
            let (next, overflow) = encodedByteCount.addingReportingOverflow(count)
            guard !overflow, next <= maximumEstimatedContentByteCount else { throw MobilePackageError.invalidEnvelope }
            encodedByteCount = next
        }
    }

    private static func validString(_ value: String) -> Bool { value.utf8.count <= maximumStringByteCount }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let type: FileAttributeType
    }

    private final class PrivateStaging: @unchecked Sendable {
        let parentDescriptor: Int32
        let name: String
        let url: URL
        let descriptor: Int32
        let identity: FileIdentity

        private var published = false
        private var finished = false

        init(parentDescriptor: Int32, name: String, url: URL, descriptor: Int32, identity: FileIdentity) {
            self.parentDescriptor = parentDescriptor
            self.name = name
            self.url = url
            self.descriptor = descriptor
            self.identity = identity
        }

        func markPublished() { published = true }

        func finish() {
            guard !finished else { return }
            finished = true
            if !published,
               MobilePackageService.sameStableIdentity(identity, MobilePackageService.identity(ofFD: descriptor)),
               MobilePackageService.sameStableIdentity(identity, MobilePackageService.identity(at: parentDescriptor, name: name)) {
                for child in [MobilePackageService.manifestFileName, MobilePackageService.encryptedPayloadFileName] {
                    _ = child.withCString { Darwin.unlinkat(descriptor, $0, 0) }
                }
                _ = name.withCString { Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
            }
            Darwin.close(descriptor)
            Darwin.close(parentDescriptor)
        }
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

    private static func identity(ofFD descriptor: Int32) -> FileIdentity? {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { return nil }
        let mode = status.st_mode & S_IFMT
        let type: FileAttributeType
        switch mode {
        case S_IFDIR: type = .typeDirectory
        case S_IFREG: type = .typeRegular
        default: type = .typeSymbolicLink
        }
        return FileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size), type: type)
    }

    private static func identity(at directoryFD: Int32, name: String) -> FileIdentity? {
        var status = stat()
        let result = name.withCString { Darwin.fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW) }
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

    static func directoryEntriesForTesting(
        _ directoryFD: Int32,
        duplicating: @Sendable (Int32) -> Int32,
        opening: @Sendable (Int32) -> UnsafeMutablePointer<DIR>?
    ) throws -> Set<String> {
        try directoryEntries(directoryFD, duplicating: duplicating, opening: opening)
    }

    private static func directoryEntries(
        _ directoryFD: Int32,
        duplicating: @Sendable (Int32) -> Int32,
        opening: @Sendable (Int32) -> UnsafeMutablePointer<DIR>? = { Darwin.fdopendir($0) }
    ) throws -> Set<String> {
        let duplicate = duplicating(directoryFD)
        guard duplicate >= 0 else { throw MobilePackageError.malformedPackage }
        guard let stream = opening(duplicate) else {
            Darwin.close(duplicate)
            throw MobilePackageError.malformedPackage
        }
        defer { Darwin.closedir(stream) }
        var entries = Set<String>()
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { entries.insert(name) }
            if entries.count > 2 { throw MobilePackageError.malformedPackage }
        }
        guard errno == 0 else { throw MobilePackageError.malformedPackage }
        return entries
    }

    private static func writeFile(at directoryFD: Int32, name: String, data: Data) throws {
        let descriptor = name.withCString { Darwin.openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw MobilePackageError.stagingFailed }
        defer { Darwin.close(descriptor) }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            guard count > 0 else { throw MobilePackageError.stagingFailed }
            offset += count
        }
        guard Darwin.fsync(descriptor) == 0 else { throw MobilePackageError.stagingFailed }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1, status.st_size == bytes.count else {
            throw MobilePackageError.stagingFailed
        }
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

    private static func createPrivateStaging(
        in replacementDirectory: URL,
        testingExportStep: @Sendable (MobilePackageExportTestStep, URL) -> Void
    ) throws -> PrivateStaging {
        let replacementRoot = replacementDirectory.path
        let parentDescriptor = replacementRoot.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard parentDescriptor >= 0 else { throw MobilePackageError.stagingFailed }
        var template = Array((replacementRoot + "/AstroMobileTransport-XXXXXXXX").utf8).map(CChar.init) + [0]
        guard let path = template.withUnsafeMutableBufferPointer({ Darwin.mkdtemp($0.baseAddress) }) else {
            Darwin.close(parentDescriptor)
            throw MobilePackageError.stagingFailed
        }
        let url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        let name = url.lastPathComponent
        guard let provisionalIdentity = identity(at: parentDescriptor, name: name), provisionalIdentity.type == .typeDirectory else {
            Darwin.close(parentDescriptor)
            throw MobilePackageError.stagingFailed
        }
        var descriptor: Int32 = -1
        var transferredOwnership = false
        defer {
            if !transferredOwnership {
                if descriptor >= 0 { Darwin.close(descriptor) }
                if sameStableIdentity(provisionalIdentity, identity(at: parentDescriptor, name: name)) {
                    _ = name.withCString { Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR) }
                }
                Darwin.close(parentDescriptor)
            }
        }
        testingExportStep(.afterProvisionalIdentity, url)
        descriptor = name.withCString { Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0,
              let identity = identity(ofFD: descriptor),
              identity.type == .typeDirectory,
              sameStableIdentity(provisionalIdentity, identity) else {
            throw MobilePackageError.stagingFailed
        }
        guard Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw MobilePackageError.stagingFailed
        }
        transferredOwnership = true
        return PrivateStaging(parentDescriptor: parentDescriptor, name: name, url: url, descriptor: descriptor, identity: identity)
    }

    private static func sameStableIdentity(_ lhs: FileIdentity?, _ rhs: FileIdentity?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.type == rhs.type
    }

    private static func publishExclusively(
        parentFD: Int32,
        destinationName: String,
        staging: PrivateStaging,
        testingExportStep: @Sendable (MobilePackageExportTestStep, URL) -> Void,
        destination: URL
    ) throws {
        guard Darwin.fsync(staging.descriptor) == 0 else { throw MobilePackageError.stagingFailed }
        testingExportStep(.beforePublication, staging.url)
        guard sameStableIdentity(staging.identity, identity(ofFD: staging.descriptor)),
              sameStableIdentity(staging.identity, identity(at: staging.parentDescriptor, name: staging.name)) else {
            throw MobilePackageError.stagingFailed
        }
        let result = staging.name.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                Darwin.renameatx_np(staging.parentDescriptor, sourcePath, parentFD, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw MobilePackageError.destinationExists }
            throw MobilePackageError.stagingFailed
        }
        staging.markPublished()
        testingExportStep(.afterRename, destination)
        guard sameStableIdentity(staging.identity, identity(at: parentFD, name: destinationName)) else {
            throw MobilePackageError.stagingFailed
        }
    }

    private static func summary(for snapshot: MobileLibrarySnapshot?) -> MobileSnapshotSummary {
        guard let snapshot else {
            return MobileSnapshotSummary(projectCount: 0, nightCount: 0, captureCount: 0, briefingCount: 0, noteCount: 0, checklistItemCount: 0)
        }
        return MobileSnapshotSummary(
            projectCount: snapshot.projects.count,
            nightCount: snapshot.nights.count,
            captureCount: snapshot.captures.count,
            briefingCount: snapshot.briefings.count,
            noteCount: snapshot.notes.count,
            checklistItemCount: snapshot.briefings.reduce(0) { total, briefing in
                total + briefing.checklist.reduce(0) { $0 + $1.items.count }
            }
        )
    }
}
