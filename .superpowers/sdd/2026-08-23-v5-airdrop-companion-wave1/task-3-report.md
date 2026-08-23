# Task 3 Report: Authenticated encrypted `.astromobile` package

## RED/GREEN evidence

### RED

Before the transport implementation existed, the required focused run was:

```text
swift test --filter MobilePackageCryptoTests
```

SwiftPM failed for the intended missing-target reason:

```text
Source files for target AstroMobileTransport should be located under 'Sources/AstroMobileTransport'
```

### GREEN

Final focused runs:

```text
swift test --filter MobilePackageCryptoTests
```

```text
Test run with 8 tests in 0 suites passed
```

```text
swift test --filter MobilePackageServiceTests
```

```text
Test run with 6 tests in 0 suites passed
```

```text
swift test --filter MobilePackage
```

```text
Test run with 14 tests in 0 suites passed
```

The focused tests cover ChaChaPoly round-trip, independent nonce/ciphertext/tag tampering, wrong keys, QR key validation/wrapping, valid export/import, hash and format failures, truncated payloads, duplicate/replay semantics, existing destinations, atomic publication, and authenticated component tampering.

## Implementation and safety self-review

- Added the cross-platform `AstroMobileTransport` product/target/test target and the `AstroApplication` transport dependency.
- `MobilePackageCrypto` uses CryptoKit ChaChaPoly, random 256-bit content keys, random nonces, mutable authenticated payload components, SHA-256 helpers, and typed non-plaintext-leaking errors.
- `OneTimePackageKey` creates a versioned canonical Base64URL QR payload and wraps content keys under the QR key; no plaintext content key is written into production packages.
- `UTType.astroMobile` is defined with the exact exported identifier and package conformance.
- Package export serializes only the typed mobile envelope inside the authenticated payload. The public manifest contains only the Task 1 metadata fields and wrapped-key text.
- Export writes an operation-private sibling staging package and publishes with an exclusive atomic move; existing destinations are never overwritten and failed staging cleanup is limited to that temporary artifact.
- Import validates package shape, manifest keys/versions/counts/hashes, payload size, wrapped-key data, authenticated decryption, envelope structure, schema, collection limits, and change IDs before staging anything. Source documents are never modified or removed.
- `commitImport(packageID:)` returns the exact staged envelope once; duplicate previews and replayed commits fail closed.
- No library-root or `WriteGuard` paths are touched by this task. No Network/Bonjour, CloudKit, UI, or Task 4+ code was added.

## Full-suite result

```text
swift test --no-parallel
```

```text
Test run with 3399 tests in 216 suites passed after 95.921 seconds.
```

```text
git diff --cached --check
```

Clean.

## Changed files

- `Package.swift`
- `Sources/AstroMobileTransport/MobilePackageCrypto.swift`
- `Sources/AstroMobileTransport/MobilePackageService.swift`
- `Sources/AstroMobileTransport/MobilePackageType.swift`
- `Tests/AstroMobileTransportTests/MobilePackageCryptoTests.swift`
- `Tests/AstroMobileTransportTests/MobilePackageServiceTests.swift`
- `Tests/AstroCoreTests/V2PackageSurfaceTests.swift` (updated package dependency assertion)

## Concerns

None within Task 3 scope. Paired-device key wrapping remains an injected interface for later pairing work; only the one-time QR wrapper is implemented in this wave, as required.
