import CryptoKit
import Foundation
import Testing
@testable import AstroMobileTransport

@Test func sealedPayloadRoundTrips() throws {
    let key = SymmetricKey(size: .bits256)
    let sealed = try MobilePackageCrypto.seal(Data("snapshot".utf8), using: key)
    #expect(try MobilePackageCrypto.open(sealed, using: key) == Data("snapshot".utf8))
}

@Test func changingCiphertextIsRejected() throws {
    let key = SymmetricKey(size: .bits256)
    var sealed = try MobilePackageCrypto.seal(Data("snapshot".utf8), using: key)
    sealed.ciphertext[0] ^= 1
    #expect(throws: MobilePackageError.self) { try MobilePackageCrypto.open(sealed, using: key) }
}

@Test func changingNonceIsRejected() throws {
    let key = SymmetricKey(size: .bits256)
    var sealed = try MobilePackageCrypto.seal(Data("snapshot".utf8), using: key)
    sealed.nonce[0] ^= 1
    #expect(throws: MobilePackageError.self) { try MobilePackageCrypto.open(sealed, using: key) }
}

@Test func changingTagIsRejected() throws {
    let key = SymmetricKey(size: .bits256)
    var sealed = try MobilePackageCrypto.seal(Data("snapshot".utf8), using: key)
    sealed.tag[0] ^= 1
    #expect(throws: MobilePackageError.self) { try MobilePackageCrypto.open(sealed, using: key) }
}

@Test func wrongKeyIsRejected() throws {
    let sealed = try MobilePackageCrypto.seal(Data("snapshot".utf8), using: SymmetricKey(size: .bits256))
    #expect(throws: MobilePackageError.self) {
        try MobilePackageCrypto.open(sealed, using: SymmetricKey(size: .bits256))
    }
}

@Test func authenticatedDataIsRequiredAndTamperIsRejected() throws {
    let key = SymmetricKey(size: .bits256)
    let sealed = try MobilePackageCrypto.seal(Data("snapshot".utf8), using: key, authenticating: Data("package-header".utf8))
    #expect(try MobilePackageCrypto.open(sealed, using: key, authenticating: Data("package-header".utf8)) == Data("snapshot".utf8))
    #expect(throws: MobilePackageError.authenticationFailed) {
        try MobilePackageCrypto.open(sealed, using: key, authenticating: Data("changed-header".utf8))
    }
}

@Test func oneTimeKeyQRPayloadRoundTripsAndWraps() throws {
    let key = OneTimePackageKey()
    let scanned = try OneTimePackageKey(qrPayload: key.qrPayload)
    let contentKey = SymmetricKey(size: .bits256)
    let wrapped = try scanned.wrap(contentKey)
    let unwrapped = try scanned.unwrap(wrapped)
    let unwrappedBytes = unwrapped.withUnsafeBytes { Data($0) }
    let originalBytes = contentKey.withUnsafeBytes { Data($0) }
    #expect(unwrappedBytes == originalBytes)
}

@Test func malformedOneTimeKeyPayloadIsRejected() {
    #expect(throws: MobilePackageError.self) {
        try OneTimePackageKey(qrPayload: "astrotool-mobile-key:v1:not-base64")
    }
}

@Test func oneTimeKeyRejectsNonCanonicalBase64URL() throws {
    let key = OneTimePackageKey()
    #expect(throws: MobilePackageError.self) {
        try OneTimePackageKey(qrPayload: key.qrPayload + "=")
    }
}
