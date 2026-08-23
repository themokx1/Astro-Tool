import Foundation

public struct MobilePackageEnvelope: Codable, Equatable, Sendable {
    public let snapshot: MobileLibrarySnapshot?
    public let changes: [MobileChange]
    public let acknowledgedChangeIDs: [UUID]

    public init(
        snapshot: MobileLibrarySnapshot?,
        changes: [MobileChange],
        acknowledgedChangeIDs: [UUID]
    ) {
        self.snapshot = snapshot
        self.changes = changes
        self.acknowledgedChangeIDs = acknowledgedChangeIDs
    }
}

public struct MobileSnapshotSummary: Codable, Equatable, Sendable {
    public let projectCount: Int
    public let nightCount: Int
    public let captureCount: Int
    public let briefingCount: Int
    public let noteCount: Int

    public init(
        projectCount: Int,
        nightCount: Int,
        captureCount: Int,
        briefingCount: Int,
        noteCount: Int
    ) {
        self.projectCount = projectCount
        self.nightCount = nightCount
        self.captureCount = captureCount
        self.briefingCount = briefingCount
        self.noteCount = noteCount
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
