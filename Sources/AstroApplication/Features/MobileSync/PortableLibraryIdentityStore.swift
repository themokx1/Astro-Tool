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
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var pendingProposals: [String: UUID] = [:]
    }

    public static let relativePath = ".astro_tool/mobile/library-id"
    private let state: State

    public init() {
        state = State()
    }

    /// Reads the current identity, or proposes one without touching the root.
    public func preview(root: URL) throws -> PortableIdentityPreview {
        let destination = root.appendingPathComponent(Self.relativePath, isDirectory: false)
        if !FileManager.default.fileExists(atPath: destination.path) {
            let key = root.standardizedFileURL.path
            state.lock.lock()
            let proposal = state.pendingProposals[key] ?? UUID()
            state.pendingProposals[key] = proposal
            state.lock.unlock()
            return PortableIdentityPreview(
                proposedID: PortableLibraryID(rawValue: proposal),
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
        guard previewed.proposedID == confirmedID else {
            throw AstroError.invalidInput("The confirmed portable library identity differs from the preview.")
        }
        _ = try WriteGuard(root: root).createPortableLibraryIdentity(confirmedID.rawValue.uuidString)
        state.lock.lock()
        state.pendingProposals.removeValue(forKey: root.standardizedFileURL.path)
        state.lock.unlock()
        return confirmedID
    }
}
