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
        try seal(plaintext, using: key, authenticating: Data())
    }

    public static func seal(
        _ plaintext: Data,
        using key: SymmetricKey,
        authenticating authenticatedData: Data
    ) throws -> MobileSealedPayload {
        guard key.bitCount == 256 else { throw MobilePackageError.invalidKey }
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: authenticatedData)
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
        try open(sealed, using: key, authenticating: Data())
    }

    public static func open(
        _ sealed: MobileSealedPayload,
        using key: SymmetricKey,
        authenticating authenticatedData: Data
    ) throws -> Data {
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
            return try ChaChaPoly.open(box, using: key, authenticating: authenticatedData)
        } catch let error as MobilePackageError {
            throw error
        } catch {
            throw MobilePackageError.authenticationFailed
        }
    }

    static func combinedBytes(_ sealed: MobileSealedPayload) -> Data {
        var data = Data()
        data.reserveCapacity(sealed.nonce.count + sealed.ciphertext.count + sealed.tag.count)
        data.append(contentsOf: sealed.nonce)
        data.append(contentsOf: sealed.ciphertext)
        data.append(contentsOf: sealed.tag)
        return data
    }

    static func openCombined(_ data: Data, using key: SymmetricKey, authenticating authenticatedData: Data) throws -> Data {
        guard key.bitCount == 256, data.count >= nonceByteCount + tagByteCount else { throw MobilePackageError.invalidSealedPayload }
        let nonceEnd = nonceByteCount
        let tagStart = data.count - tagByteCount
        do {
            let nonce = try ChaChaPoly.Nonce(data: data[..<nonceEnd])
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: data[nonceEnd..<tagStart],
                tag: data[tagStart...]
            )
            return try ChaChaPoly.open(box, using: key, authenticating: authenticatedData)
        } catch {
            throw MobilePackageError.authenticationFailed
        }
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

/// Wraps a package content key for a "paired device" transfer carried over
/// an already-authenticated `NearbySecureChannel` session (Wave 2's
/// `NearbyPackageTransport`), instead of being scanned from a QR code.
///
/// ## Why this is not literal Curve25519 key agreement to the peer's stored key
/// The plan's original sketch described `pairedDevice` as "content key
/// wrapped to the stored peer public key." `MobilePeerIdentity` (Wave 2's
/// `MobileDeviceIdentity.swift`), however, stores only a persistent
/// Curve25519 **signing** key (Ed25519-style) — it authenticates ephemeral
/// session keys during pairing and is never an agreement key. Reusing a
/// signing key for X25519 key agreement is a known-unsound construction
/// (the two primitives are not meant to share scalars), and CryptoKit
/// deliberately keeps `Curve25519.Signing` and `Curve25519.KeyAgreement`
/// unconvertible from one another. Wave 2's identity model carries no
/// agreement key at all, so a literal "ECDH to the stored peer public key"
/// wrap cannot be built without extending `MobileDeviceIdentity` — out of
/// scope for the package-transport task.
///
/// ## Why this is not `wrappedContentKeyBase64: nil` either
/// `MobilePackageService.export` always calls `wrapping.wrap(contentKey)`
/// and rejects an empty result (`guard !wrappedKey.isEmpty`), then always
/// persists `wrappedKey.base64EncodedString()` into the manifest — there is
/// no export entry point that leaves `wrappedContentKeyBase64` nil.
/// `authenticatePreview` is symmetric: it requires a non-nil, non-empty
/// `wrappedContentKeyBase64` and always calls `wrapping.unwrap(...)` on it.
/// So "the content key travels bare, only inside the channel, with no
/// wrapped-key manifest field at all" is not expressible through the
/// existing, unmodified Wave 1 API without bending its validation.
///
/// ## The design actually used
/// `PairedDeviceKeyWrapping` is cryptographically identical to
/// `OneTimePackageKey` — a random 256-bit AEAD key wraps/unwraps the
/// content key via `MobilePackageCrypto.seal`/`open` — but is a **distinct
/// Swift type**, so `MobilePackageService.export`'s `wrapping is
/// OneTimePackageKey` check tags the manifest `keyMode: .pairedDevice`
/// rather than `.oneTimeQR`. The only real difference from the QR flow is
/// how the wrap key reaches the other side: instead of a human
/// photographing a QR code, `NearbyPackageTransport` carries the wrap key's
/// raw 32 bytes as a field of the `.packageManifest` `NearbySessionMessage`
/// — a message that is only ever sent through `NearbySecureChannel.send`,
/// i.e. sealed under the pairing session's authenticated, forward-secret
/// traffic key and bound (via the handshake) to both device identities.
/// This realizes the plan's "the channel IS the key transport" ruling
/// through the exact extension point Wave 1 already designed for this
/// purpose (`MobilePackageKeyWrapping`), with no change to
/// `MobilePackageService`'s crypto or validation.
public struct PairedDeviceKeyWrapping: MobilePackageKeyWrapping, Sendable, Equatable {
    private let rawKey: Data

    /// Mints a fresh per-transfer wrap key. `NearbyPackageTransport.send`
    /// calls this once per package export.
    public init() {
        let key = SymmetricKey(size: .bits256)
        self.rawKey = key.withUnsafeBytes { Data($0) }
    }

    /// Reconstructs the wrap key from the raw bytes the sender carried
    /// inside the `.packageManifest` message.
    /// `NearbyPackageTransport.receive` calls this. `rawRepresentation` must
    /// be exactly 32 bytes — a peer-supplied value of any other length is
    /// malformed input, not a legitimately different key.
    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32 else { throw MobilePackageError.invalidKey }
        self.rawKey = rawRepresentation
    }

    /// The bytes to carry inside the secure channel. Never written to disk
    /// outside the sender's own transient export staging, never shown to a
    /// user, never sent outside the authenticated session.
    public var rawRepresentation: Data { rawKey }

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
}
