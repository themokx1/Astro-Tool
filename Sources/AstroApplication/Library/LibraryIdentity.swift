import CryptoKit
import Foundation

public struct LibraryIdentity: Codable, Hashable, Sendable {
    public let id: String

    let canonicalRootURL: URL?

    public init(rootURL: URL) {
        let canonicalRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.id = SHA256.hash(data: Data(canonicalRootURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        self.canonicalRootURL = canonicalRootURL
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private enum CodingKeys: String, CodingKey {
        case id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.canonicalRootURL = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
    }
}
