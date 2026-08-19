import Foundation
import Testing

@Suite("Release packaging surface")
struct ReleasePackagingSurfaceTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("Normal builds are Universal and never install as a side effect")
    func universalBuildIsNonInstalling() throws {
        let build = try source("build.sh")
        #expect(build.contains("--arch arm64"))
        #expect(build.contains("--arch x86_64"))
        #expect(build.contains("LSApplicationCategoryType"))
        #expect(build.contains("NSHumanReadableCopyright"))
        #expect(!build.contains("INSTALL_DIR="))
        #expect(!build.contains("Symlinking CLI onto PATH"))
    }

    @Test("Installation is an explicit recoverable action")
    func explicitInstaller() throws {
        let installer = try source("scripts/install-local.sh")
        #expect(installer.contains("/Applications"))
        #expect(installer.contains("AstroTool.previous"))
        #expect(installer.contains("AstroTool.failed-install"))
        #expect(installer.contains("ditto"))
        #expect(installer.contains("mv \"$BACKUP_APP\" \"$DESTINATION_APP\""))
        #expect(installer.contains("verify_installed_app"))
        #expect(installer.contains("CFBundleShortVersionString"))
        #expect(installer.contains("CFBundleIdentifier"))
        #expect(installer.contains("codesign --verify --deep --strict"))
        #expect(installer.contains("Contents/Resources/astrotool"))
        #expect(installer.contains("lipo -archs"))
    }

    @Test("CI proves a neutral app launch and a selected empty-library first-run path")
    func cleanInstallSmokeGate() throws {
        let smoke = try source("scripts/smoke-clean-install.sh")
        let workflow = try source(".github/workflows/ci.yml")
        #expect(smoke.contains("ASTROTOOL_DEFAULTS_SUITE"))
        #expect(smoke.contains("ASTROTOOL_CLEAN_INSTALL_SMOKE_LIBRARY=\"$SMOKE_LIBRARY\""))
        #expect(smoke.contains("-ResetOnboarding"))
        #expect(smoke.contains("cleanInstallSmokeReachedFirstScan"))
        // V2 architecture (2026-08-20): metadata lives OUTSIDE the library
        // (~/Library/Caches/AstroTool/Libraries/<id>/index.sqlite) and the
        // app auto-indexes read-only on open BY DESIGN -- the smoke asserts
        // the external index appears and the library itself stays untouched,
        // replacing the V1-era in-library .astro_tool/astrotool.sqlite and
        // "no scan without a user choice" checks.
        #expect(smoke.contains("Caches/AstroTool/Libraries"))
        #expect(smoke.contains("index.sqlite"))
        #expect(smoke.contains("! -name .astro_tool"))
        #expect(!smoke.contains("astrotool.sqlite"))
        #expect(smoke.contains("kill -0"))
        #expect(workflow.contains("scripts/smoke-clean-install.sh"))
    }

    @Test("Public release requires signing and notarization")
    func signedNotarizedRelease() throws {
        let release = try source("scripts/release.sh")
        #expect(release.contains("DEVELOPER_ID_APPLICATION"))
        #expect(release.contains("NOTARY_PROFILE"))
        #expect(release.contains("notarytool submit"))
        #expect(release.contains("stapler staple"))
        #expect(release.contains("codesign --force --sign \"$DEVELOPER_ID_APPLICATION\" --timestamp \"$DMG\""))
        #expect(release.contains("spctl --assess --type open"))

        let workflow = try source(".github/workflows/release.yml")
        #expect(workflow.contains("DEVELOPER_ID_CERTIFICATE_BASE64"))
        #expect(workflow.contains("NOTARYTOOL_PRIVATE_KEY_BASE64"))
        #expect(workflow.contains("scripts/release.sh"))
    }

    @Test("Public artifacts include checksums")
    func checksummedArtifacts() throws {
        let build = try source("build.sh")
        #expect(build.contains("SHA256SUMS.txt"))
        #expect(build.contains("COPYFILE_DISABLE=1 ditto -c -k --keepParent"))
        let workflow = try source(".github/workflows/release.yml")
        #expect(workflow.contains("SHA256SUMS.txt"))
    }

    @Test("Versioned release documentation is complete and public-safe")
    func releaseDocumentation() throws {
        let notes = try source("docs/releases/v1.0.0.md")
        let changelog = try source("CHANGELOG.md")
        let readme = try source("README.md")
        let check = try source("scripts/check-public-content.sh")
        let metadataCheck = try source("scripts/check-release-metadata.sh")

        #expect(notes.contains("AstroTool 1.0.0"))
        #expect(notes.contains("Universal"))
        #expect(notes.contains("Biztonságos diagnosztika"))
        #expect(changelog.contains("## [1.0.0] - 2026-08-10"))
        #expect(readme.contains("Tiszta telepítéskor nincs előre felvett felszerelés"))
        #expect(check.contains("Public content check passed."))
        #expect(metadataCheck.contains("docs/releases/v$VERSION.md"))
        #expect(metadataCheck.contains("CHANGELOG.md"))
        #expect(metadataCheck.contains("Release metadata check passed."))
    }

    @Test("Public website identifies the current V2 product")
    func websiteIdentifiesV2() throws {
        let homepage = try source("docs/index.html")
        #expect(homepage.contains("AstroTool 2.0"))
        #expect(homepage.contains("Project → Night → Series → Frame → Result"))
        #expect(!homepage.contains("AstroTool 1.0"))
    }
}
