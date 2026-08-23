import Foundation
import AstroCore
import AstroMobileDomain

public struct PortableIdentityPreview: Equatable, Sendable {
    public let proposedID: PortableLibraryID
    public let relativePath: String
    public let alreadyExists: Bool

    public init(proposedID: PortableLibraryID, relativePath: String, alreadyExists: Bool) {
        self.proposedID = proposedID
        self.relativePath = relativePath
        self.alreadyExists = alreadyExists
    }
}

public struct PortableLibraryIdentityStore: Sendable {
    public static let relativePath = ".astro_tool/mobile/library-id"

    public init() {}

    /// Reads the current identity, or proposes one without touching the root.
    public func preview(root: URL) throws -> PortableIdentityPreview {
        let destination = root.appendingPathComponent(Self.relativePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return PortableIdentityPreview(
                proposedID: PortableLibraryID(rawValue: UUID()),
                relativePath: Self.relativePath,
                alreadyExists: false
            )
        }

        guard let text = try? String(contentsOf: destination, encoding: .utf8),
              let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw AstroError.invalidInput("The existing portable library identity is malformed.")
        }
        return PortableIdentityPreview(
            proposedID: PortableLibraryID(rawValue: uuid),
            relativePath: Self.relativePath,
            alreadyExists: true
        )
    }

    /// Commits only the identity that the preceding UI preview confirmed.
    public func loadOrCreate(root: URL, confirmedID: PortableLibraryID) throws -> PortableLibraryID {
        let previewed = try preview(root: root)
        guard !previewed.alreadyExists || previewed.proposedID == confirmedID else {
            throw AstroError.invalidInput("The confirmed portable library identity differs from the preview.")
        }
        _ = try WriteGuard(root: root).createPortableLibraryIdentity(confirmedID.rawValue.uuidString)
        return confirmedID
    }
}
