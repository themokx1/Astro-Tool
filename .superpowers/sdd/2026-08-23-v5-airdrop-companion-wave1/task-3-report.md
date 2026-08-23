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

## Security fix round 1 — threat-model remediation

### RED evidence

Added `tamperedManifestIdentityIsAuthenticatedAndRejected` before changing production code. The service accepted a changed public `packageID`, and the exact assertion failed because no authentication error was raised. This demonstrated that manifest identity was not bound to the ciphertext.

### GREEN evidence

The remediation now:

- binds canonical format version, package ID, creation time, and key mode as ChaChaPoly authenticated data;
- encrypts an authenticated payload wrapper containing the package ID and rejects a wrapper/manifest mismatch as `.packageIDMismatch`;
- uses an exclusive Darwin `renameatx_np(..., RENAME_EXCL)` publication primitive;
- uses `lstat`-based file identities and identity checks around reads and temporary cleanup;
- rejects symlink/non-regular package children;
- caps manifest bytes (64 KiB), encrypted payload bytes (16 MiB), JSON depth (32), string UTF-8 bytes (256 KiB), collections (10,000), nested records (50,000), staged imports (8), and staged encrypted bytes (32 MiB);
- performs bounded JSON structural traversal and exact per-model key validation before Codable model allocation;
- validates finite numeric values, nonnegative revisions, unique IDs, capture references, and mobile change references before staging;
- uses a combined-payload open path to avoid an unnecessary sealed `[UInt8]` reconstruction during import.

New security tests cover exact error cases for manifest-ID AAD tampering, unknown/forbidden envelope fields, future snapshot schema, oversized manifests, oversized nested collections, source immutability, symlink children, actor-scoped replay, and cross-instance replay semantics.

Final security-fix verification:

```text
swift test --filter MobilePackageCryptoTests
```

```text
Test run with 9 tests in 0 suites passed
```

```text
swift test --filter MobilePackageServiceTests
```

```text
Test run with 11 tests in 0 suites passed
```

```text
swift test --filter MobilePackage
```

```text
Test run with 20 tests in 0 suites passed
```

```text
swift test --no-parallel
```

```text
Test run with 3405 tests in 216 suites passed after 97.483 seconds.
```

`git diff --check` is clean. Replay semantics are intentionally actor-scoped in this transport wave: duplicate staged/committed package IDs fail within one `MobilePackageService` actor, while a fresh actor can preview the same immutable source. Durable replay/idempotency storage belongs to the Task 7 importer and is explicitly deferred; no library writes were introduced here.

## Security fix round 2 — reviewer remediation

### Threat-model RED evidence

The review identified four Important attack classes. Tests were added first and encode the expected fail-closed behavior:

- A real composed snapshot with all four optional Codable fields (`goalHours`, `filterName`, `nightDate`, and `explanation`) omitted must round-trip. Nested `libraryID` unknown/forbidden keys must fail with the exact `.invalidEnvelope` case.
- A token-dense/deep authenticated JSON payload and an export containing a string beyond the explicit phone limit must fail with `.invalidEnvelope` before staging or model allocation.
- Symlink and hard-link package children must fail with `.malformedPackage`; an existing destination must leave no operation-private `.staging-*` directory behind.
- Checklist IDs duplicated across sections of one briefing, a briefing referencing a missing note, and note changes with the wrong owner or a non-editable note must each fail with `.invalidEnvelope`.

### Threat-model GREEN evidence

The implementation now:

- distinguishes required and allowed-optional JSON keys and exact-validates `libraryID` as `{rawValue}`;
- runs a bounded lexical JSON preflight before `JSONSerialization`/`JSONDecoder`, with explicit 32-level depth, 50,000-record-derived node, 10,000-array-member, 32-object-member, 256 KiB-string, and 128-byte-number-token limits;
- applies the same aggregate nested-record bound during export, and checks encoded plaintext, combined ciphertext, wrapped key, and manifest sizes before publication;
- opens the package directory once and reads fixed children using `openat` with `O_NOFOLLOW`, `fstat`, regular-file and single-link checks, bounded owned `Data`, and post-read descriptor identity/size verification; mapped payload reads are no longer used;
- cleans operation-private staging through a parent/child descriptor and stable device/inode/type identity, avoiding mutable directory-size comparisons;
- precomputes briefing item and note maps for linear semantic-reference validation, enforces item-ID uniqueness per briefing, requires briefing note references, and checks note owner/editability for note changes.

Round-2 security tests added: 5 (composed optional-field round-trip, nested schema rejection, token/oversized export limits, hard-link rejection, and semantic reference validation). The service security test set now contains 16 tests.

Replay semantics remain intentionally actor-scoped: duplicate staged/committed package IDs fail within one service actor; durable replay/idempotency persistence remains Task 7 and no transport-layer library writes were added.

## Security fix round 3 — final same-implementer remediation

### RED/GREEN evidence

- Import now opens the package directory first, fstats and binds its device/inode/type to the initial identity, and enumerates the exact two children through that retained descriptor. Child reads remain `openat(..., O_NOFOLLOW)`/descriptor-relative with regular-file, single-link, size, and post-read identity checks.
- Export opens and retains the destination parent descriptor, creates the private staging directory with `mkdirat`, creates both files with descriptor-relative `openat(..., O_CREAT|O_EXCL|O_NOFOLLOW)`, writes/fsyncs/fstats them, verifies the staging identity, and publishes with descriptor-relative `renameatx_np(..., RENAME_EXCL)`. Cleanup uses the retained parent descriptor and stable staging identity, so a replacement entry is not unlinked.
- Export validation now performs overflow-checked aggregate UTF-8 accounting across every snapshot/domain/change ID, text, optional string, warning, and scope string; enforces every nested per-array cap and an explicit 8 MiB estimated-content budget before `JSONEncoder` allocation. Encoded plaintext, ciphertext, wrapped key, and manifest caps remain enforced afterward.
- The lexical preflight now counts decoded UTF-8 bytes, validates raw UTF-8 scalars, combines valid surrogate pairs, rejects isolated/invalid surrogates, applies the decoded 128-byte key limit, and rejects trailing/top-level data.
- Wrapped-key limits are symmetric at 4096 decoded bytes; import additionally requires canonical Base64 re-encoding and rejects oversize/noncanonical values.
- Briefing note references now require a `.briefing` note whose owner ID equals the briefing UUID; tests separately cover wrong owner and non-editable notes.

### Round-3 verification evidence

```text
swift test --filter MobilePackageServiceTests
Test run with 19 tests in 0 suites passed after 0.221 seconds.
```

```text
swift test --filter MobilePackage
Test run with 28 tests in 0 suites passed after 0.223 seconds.
```

```text
swift test --filter MobilePackageCryptoTests
Test run with 9 tests in 0 suites passed after 0.001 seconds.
```

```text
swift test --no-parallel
Test run with 3413 tests in 216 suites passed after 98.133 seconds.
```

```text
git diff --check
git diff --cached --check
```

Both diff checks were clean before commit. Round-3 tests cover descriptor-bound package listing, no-follow hard/symbolic link rejection, staging cleanup, aggregate warning/nested-array limits, lexical Unicode and trailing-data boundaries, symmetric wrapped-key limits, and independent semantic owner/editability failures.
