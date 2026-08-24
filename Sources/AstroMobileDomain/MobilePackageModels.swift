import Foundation

public struct MobilePackageEnvelope: Codable, Equatable, Sendable {
    public let purpose: MobilePackagePurpose
    public let snapshot: MobileLibrarySnapshot?
    public let baseSnapshotID: UUID?
    public let changes: [MobileChange]
    public let acknowledgedChangeIDs: [UUID]

    public init(
        purpose: MobilePackagePurpose = .forwardSnapshot,
        snapshot: MobileLibrarySnapshot?,
        baseSnapshotID: UUID? = nil,
        changes: [MobileChange],
        acknowledgedChangeIDs: [UUID]
    ) {
        self.purpose = purpose
        self.snapshot = snapshot
        self.baseSnapshotID = baseSnapshotID
        self.changes = changes
        self.acknowledgedChangeIDs = acknowledgedChangeIDs
    }
}

public enum MobilePackagePurpose: String, Codable, Equatable, Sendable {
    case forwardSnapshot
    case returnChanges
}

public struct MobileSnapshotSummary: Codable, Equatable, Sendable {
    public let projectCount: Int
    public let nightCount: Int
    public let captureCount: Int
    public let briefingCount: Int
    public let noteCount: Int
    public let checklistItemCount: Int

    public init(
        projectCount: Int,
        nightCount: Int,
        captureCount: Int,
        briefingCount: Int,
        noteCount: Int,
        checklistItemCount: Int = 0
    ) {
        self.projectCount = projectCount
        self.nightCount = nightCount
        self.captureCount = captureCount
        self.briefingCount = briefingCount
        self.noteCount = noteCount
        self.checklistItemCount = checklistItemCount
    }
}

public struct MobilePackageManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public let formatVersion: Int
    public let packageID: UUID
    public let createdAt: Date
    public let encryptedByteCount: Int64
    public let ciphertextSHA256: String
    public let keyMode: MobilePackageKeyMode
    public let wrappedContentKeyBase64: String?

    public init(
        formatVersion: Int,
        packageID: UUID,
        createdAt: Date,
        encryptedByteCount: Int64,
        ciphertextSHA256: String,
        keyMode: MobilePackageKeyMode,
        wrappedContentKeyBase64: String?
    ) {
        self.formatVersion = formatVersion
        self.packageID = packageID
        self.createdAt = createdAt
        self.encryptedByteCount = encryptedByteCount
        self.ciphertextSHA256 = ciphertextSHA256
        self.keyMode = keyMode
        self.wrappedContentKeyBase64 = wrappedContentKeyBase64
    }
}

public enum MobilePackageKeyMode: String, Codable, Sendable {
    case oneTimeQR
    case pairedDevice
}
