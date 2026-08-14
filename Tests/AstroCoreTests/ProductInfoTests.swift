import Foundation
import Testing
@testable import AstroCore

@Suite("ProductInfo") struct ProductInfoTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func publicIdentityIsStableAndReleaseReady() {
        #expect(ProductInfo.name == "AstroTool")
        #expect(ProductInfo.version == "2.0.0")
        #expect(ProductInfo.releaseChannel == "Release Candidate 2")
        #expect(ProductInfo.bundleIdentifier == "io.github.themokx1.AstroTool")
        #expect(ProductInfo.legacyBundleIdentifier == "com.zoltanpalotai.astrotool")
        #expect(Int(ProductInfo.build) != nil)
        #expect(ProductInfo.displayVersion == "2.0.0 Release Candidate 2 (20013)")
    }

    @Test func releaseConsumersUseTheSharedProductInfo() throws {
        let cli = try source("Sources/astrotool/main.swift")
        let report = try source("Sources/AstroCore/Export/TargetReport.swift")
        let build = try source("build.sh")

        #expect(cli.contains("ProductInfo.version"))
        #expect(!cli.contains("astrotool 0.16.0"))
        #expect(report.contains("ProductInfo.version"))
        #expect(!report.contains("astrotool 0.16.0"))
        #expect(build.contains("ProductInfo.swift"))
        #expect(!build.contains("BUNDLE_ID=\"com.zoltanpalotai.astrotool\""))
        #expect(!build.contains("SHORT_VERSION=\"0.16.0\""))
    }
}
