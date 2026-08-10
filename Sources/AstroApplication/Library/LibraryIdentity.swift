import CryptoKit
import Foundation

public struct LibraryIdentity: Codable, Hashable, Sendable {
    public let id: String

    public init(rootURL: URL) {
        let canonicalRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.id = SHA256.hash(data: Data(canonicalRootURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
