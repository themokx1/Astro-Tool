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
        #expect(installer.contains("ditto"))
    }

    @Test("Public release requires signing and notarization")
    func signedNotarizedRelease() throws {
        let release = try source("scripts/release.sh")
        #expect(release.contains("DEVELOPER_ID_APPLICATION"))
        #expect(release.contains("NOTARY_PROFILE"))
        #expect(release.contains("notarytool submit"))
        #expect(release.contains("stapler staple"))

        let workflow = try source(".github/workflows/release.yml")
        #expect(workflow.contains("DEVELOPER_ID_CERTIFICATE_BASE64"))
        #expect(workflow.contains("NOTARYTOOL_PRIVATE_KEY_BASE64"))
        #expect(workflow.contains("scripts/release.sh"))
    }

    @Test("Public artifacts include checksums")
    func checksummedArtifacts() throws {
        let build = try source("build.sh")
        #expect(build.contains("SHA256SUMS.txt"))
        let workflow = try source(".github/workflows/release.yml")
        #expect(workflow.contains("SHA256SUMS.txt"))
    }
}
