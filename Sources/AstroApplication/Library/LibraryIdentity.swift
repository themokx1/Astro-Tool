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

    private enum CodingKeys: String, CodingKey {
        case id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard Self.isValidDigest(id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Library identity must be exactly 64 lowercase hexadecimal characters."
            )
        }
        self.id = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
    }

    private static func isValidDigest(_ id: String) -> Bool {
        let bytes = id.utf8
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}
