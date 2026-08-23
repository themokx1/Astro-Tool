# Task 1 Report: Cross-platform mobile domain and safety whitelist

## Implementation

- Added the iOS v26 platform, `AstroMobileDomain` library product and target, `AstroMobileDomainTests`, and the `AstroApplication` dependency required by the brief.
- Added the Foundation-only portable value domain in `Sources/AstroMobileDomain/MobileLibraryModels.swift`: `PortableLibraryID`, deterministic ISO-8601/sorted-key `MobileJSON`, snapshots, project/night/capture/briefing/checklist/note records, and the explicit note scope.
- Added the two-case typed change allowlist and Codable change payloads in `Sources/AstroMobileDomain/MobileChanges.swift`.
- Added typed package envelope, snapshot summary, manifest, and key-mode models in `Sources/AstroMobileDomain/MobilePackageModels.swift`.
- Added the transport-neutral async send/receive contract in `Sources/AstroMobileDomain/MobileSyncTransport.swift`.
- Added round-trip, filesystem-material exclusion, and exact change-kind tests in `Tests/AstroMobileDomainTests`.
- Updated the existing package-surface assertion so it reflects the newly required `AstroMobileDomain` dependency.

## TDD evidence

### RED

Command:

```text
swift test --filter AstroMobileDomainTests
```

Relevant output before implementation:

```text
error: Source files for target AstroMobileDomain should be located under 'Sources/AstroMobileDomain'
```

### GREEN

Command:

```text
swift test --filter AstroMobileDomainTests
```

Relevant output:

```text
Build complete!
✔ Test run with 3 tests in 0 suites passed
```

The focused tests cover snapshot Codable round-trip, forbidden filesystem material, and the exact two allowed change kinds.

## Full-suite result

Command:

```text
swift test --no-parallel
```

Result after aligning the stale package-surface expectation with the required dependency:

```text
✔ Test run with 3369 tests in 216 suites passed after 96.801 seconds.
```

## Self-review

- `git diff --check` is clean.
- The public mobile records use explicit fields and public initializers only.
- No public mobile record contains `URL`, `Data`, an untyped dictionary, a filesystem path, or a raw payload escape hatch.
- `MobileChangeKind.allCases` contains exactly `.checklistCompletion` and `.noteRevision`.
- JSON encoding is deterministic via sorted keys and ISO-8601 dates.
- The domain target imports only Foundation.

## Concerns

None. The existing package-surface test needed its expected `AstroApplication` dependency updated because the brief intentionally adds `AstroMobileDomain`.

## Round 1 remediation

Addressed both Important review findings:

- Replaced Foundation's truncating `.iso8601` strategy with a custom ISO-8601 codec that writes a 17-digit fractional-second component and decodes both fractional and whole-second timestamps.
- Expanded the privacy regression fixture to populate every snapshot record, both change payloads, the package envelope, manifest, and summary. The test recursively collects JSON object keys and requires the exact hand-derived allowlisted key set, while checking the forbidden filesystem/path/header/bookmark material across every encoded value.

### Round 1 RED evidence

After adding the regression tests and before changing production code:

```text
swift test --filter AstroMobileDomainTests
```

The focused run failed with five issues, including:

```text
Expectation failed: ... MobileChange ... == change
Expectation failed: ... MobileLibrarySnapshot ... == snapshot
Expectation failed: actualKeys == expectedAllowlistedKeys
```

### Round 1 GREEN evidence

After the custom codec and populated allowlist fixture were implemented:

```text
swift test --filter AstroMobileDomainTests
```

```text
✔ Test run with 5 tests in 0 suites passed
```

### Round 1 full verification

```text
swift test --no-parallel
```

```text
✔ Test run with 3371 tests in 216 suites passed after 96.082 seconds.
```
