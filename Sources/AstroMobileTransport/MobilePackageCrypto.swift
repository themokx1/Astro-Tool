import CryptoKit
import Foundation

public enum MobilePackageError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidKey
    case invalidSealedPayload
    case authenticationFailed
    case malformedPackage
    case invalidManifest
    case unsupportedFormatVersion
    case unsupportedSchemaVersion
    case manifestHashMismatch
    case packageIDMismatch
    case duplicatePackageID
    case destinationExists
    case sourceNotFound
    case invalidKeyPayload
    case invalidEnvelope
    case stagingFailed

    public var description: String {
        switch self {
        case .invalidKey: return "The package key is invalid."
        case .invalidSealedPayload: return "The encrypted payload format is invalid."
        case .authenticationFailed: return "The encrypted payload could not be authenticated."
        case .malformedPackage: return "The mobile package is malformed."
        case .invalidManifest: return "The mobile package manifest is invalid."
        case .unsupportedFormatVersion: return "The mobile package format is not supported."
        case .unsupportedSchemaVersion: return "The mobile package schema is not supported."
        case .manifestHashMismatch: return "The mobile package integrity check failed."
        case .packageIDMismatch: return "The mobile package identity is invalid."
        case .duplicatePackageID: return "This mobile package has already been handled."
        case .destinationExists: return "The destination already exists."
        case .sourceNotFound: return "The mobile package could not be found."
        case .invalidKeyPayload: return "The one-time key payload is invalid."
        case .invalidEnvelope: return "The mobile package contents are invalid."
        case .stagingFailed: return "The mobile package could not be staged."
        }
    }
}

public struct MobileSealedPayload: Codable, Equatable, Sendable {
    public var nonce: [UInt8]
    public var ciphertext: [UInt8]
    public var tag: [UInt8]

    public init(nonce: [UInt8], ciphertext: [UInt8], tag: [UInt8]) {
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public enum MobilePackageCrypto {
    static let nonceByteCount = 12
    static let tagByteCount = 16

    public static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> MobileSealedPayload {
        guard key.bitCount == 256 else { throw MobilePackageError.invalidKey }
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key)
            return MobileSealedPayload(
                nonce: Array(box.nonce),
                ciphertext: Array(box.ciphertext),
                tag: Array(box.tag)
            )
        } catch {
            throw MobilePackageError.invalidSealedPayload
        }
    }

    public static func open(_ sealed: MobileSealedPayload, using key: SymmetricKey) throws -> Data {
        guard key.bitCount == 256,
              sealed.nonce.count == nonceByteCount,
              sealed.tag.count == tagByteCount else {
            throw MobilePackageError.invalidSealedPayload
        }
        do {
            let nonce = try ChaChaPoly.Nonce(data: Data(sealed.nonce))
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: Data(sealed.ciphertext),
                tag: Data(sealed.tag)
            )
            return try ChaChaPoly.open(box, using: key)
        } catch let error as MobilePackageError {
            throw error
        } catch {
            throw MobilePackageError.authenticationFailed
        }
    }

    static func combinedBytes(_ sealed: MobileSealedPayload) -> Data {
        Data(sealed.nonce) + Data(sealed.ciphertext) + Data(sealed.tag)
    }

    static func payload(fromCombinedBytes data: Data) throws -> MobileSealedPayload {
        guard data.count >= nonceByteCount + tagByteCount else {
            throw MobilePackageError.invalidSealedPayload
        }
        let nonceEnd = nonceByteCount
        let tagStart = data.count - tagByteCount
        return MobileSealedPayload(
            nonce: Array(data[..<nonceEnd]),
            ciphertext: Array(data[nonceEnd..<tagStart]),
            tag: Array(data[tagStart...])
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol MobilePackageKeyWrapping: Sendable {
    func wrap(_ key: SymmetricKey) throws -> Data
    func unwrap(_ wrapped: Data) throws -> SymmetricKey
}

public struct OneTimePackageKey: MobilePackageKeyWrapping, Sendable, Equatable {
    public static let qrPrefix = "astrotool-mobile-key:v1:"

    private let rawKey: Data

    public init() {
        let key = SymmetricKey(size: .bits256)
        self.rawKey = key.withUnsafeBytes { Data($0) }
    }

    public init(qrPayload: String) throws {
        guard qrPayload.hasPrefix(Self.qrPrefix) else { throw MobilePackageError.invalidKeyPayload }
        let encoded = String(qrPayload.dropFirst(Self.qrPrefix.count))
        guard !encoded.isEmpty,
              !encoded.contains("="),
              let data = Self.decodeBase64URL(encoded),
              data.count == 32,
              Self.encodeBase64URL(data) == encoded else {
            throw MobilePackageError.invalidKeyPayload
        }
        self.rawKey = data
    }

    public init(scanning qrPayload: String) throws {
        try self.init(qrPayload: qrPayload)
    }

    public static func scan(_ qrPayload: String) throws -> OneTimePackageKey {
        try OneTimePackageKey(qrPayload: qrPayload)
    }

    public var qrPayload: String {
        Self.qrPrefix + Self.encodeBase64URL(rawKey)
    }

    public func wrap(_ key: SymmetricKey) throws -> Data {
        guard key.bitCount == 256 else { throw MobilePackageError.invalidKey }
        return MobilePackageCrypto.combinedBytes(
            try MobilePackageCrypto.seal(key.withUnsafeBytes { Data($0) }, using: SymmetricKey(data: rawKey))
        )
    }

    public func unwrap(_ wrapped: Data) throws -> SymmetricKey {
        do {
            let sealed = try MobilePackageCrypto.payload(fromCombinedBytes: wrapped)
            let plaintext = try MobilePackageCrypto.open(sealed, using: SymmetricKey(data: rawKey))
            guard plaintext.count == 32 else { throw MobilePackageError.invalidKey }
            return SymmetricKey(data: plaintext)
        } catch let error as MobilePackageError {
            throw error
        } catch {
            throw MobilePackageError.invalidKeyPayload
        }
    }

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard value.allSatisfy({ $0.isNumber || ($0 >= "A" && $0 <= "Z") || ($0 >= "a" && $0 <= "z") || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        let padding = (4 - value.count % 4) % 4
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: padding)
        return Data(base64Encoded: standard)
    }
}
