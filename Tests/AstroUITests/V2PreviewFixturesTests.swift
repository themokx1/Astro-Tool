@testable import AstroUI
import Foundation
import Testing

@Suite("V2 preview fixtures")
struct V2PreviewFixturesTests {
    @Test("A fixture-root symlink swap cannot redirect fixture creation")
    func rejectsFixtureRootSwapBeforeMutation() throws {
        let paths = try FixtureRacePaths.make()
        defer { paths.remove() }

        var didAttemptSwap = false
        do {
            _ = try V2PreviewFixtures.fixture(
                arguments: paths.arguments,
                beforeMutation: { fixtureRoot, _ in
                    didAttemptSwap = true
                    try FileManager.default.moveItem(
                        at: fixtureRoot,
                        to: paths.parkedFixtureContainer
                    )
                    try FileManager.default.createSymbolicLink(
                        at: fixtureRoot,
                        withDestinationURL: paths.realLibraryTarget
                    )
                }
            )
            Issue.record("Fixture creation should reject a replaced fixture root")
        } catch V2UITestFixtureError.rootIdentityChanged {
            // Expected: the path no longer identifies the pinned directory.
        }

        #expect(didAttemptSwap)
        #expect(!FileManager.default.fileExists(
            atPath: paths.realLibraryTarget.appendingPathComponent("DemoLibrary").path
        ))
    }

    @Test("An app-support symlink swap cannot redirect support or cache creation")
    func rejectsSupportRootSwapBeforeMutation() throws {
        let paths = try FixtureRacePaths.make()
        defer { paths.remove() }

        var didAttemptSwap = false
        do {
            _ = try V2PreviewFixtures.fixture(
                arguments: paths.arguments,
                beforeMutation: { _, supportRoot in
                    didAttemptSwap = true
                    try FileManager.default.moveItem(
                        at: supportRoot,
                        to: paths.parkedSupportContainer
                    )
                    try FileManager.default.createSymbolicLink(
                        at: supportRoot,
                        withDestinationURL: paths.realSupportTarget
                    )
                }
            )
            Issue.record("Fixture creation should reject a replaced support root")
        } catch V2UITestFixtureError.rootIdentityChanged {
            // Expected: the path no longer identifies the pinned directory.
        }

        #expect(didAttemptSwap)
        #expect(!FileManager.default.fileExists(
            atPath: paths.realSupportTarget.appendingPathComponent("ApplicationSupport").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: paths.realSupportTarget.appendingPathComponent("Caches").path
        ))
    }

    @Test("The sandbox-writable macOS temporary root is accepted without sharing TMPDIR")
    func acceptsMacOSTemporaryRoot() throws {
        let runID = UUID().uuidString
        let temporaryRoot = FileManager.default.temporaryDirectory
        let fixtureContainer = temporaryRoot.appendingPathComponent(
            "AstroTool-V2-UI-Fixture-\(runID)",
            isDirectory: true
        )
        let supportContainer = temporaryRoot.appendingPathComponent(
            "AstroTool-V2-UI-Support-\(runID)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixtureContainer)
            try? FileManager.default.removeItem(at: supportContainer)
        }

        let fixture = try V2PreviewFixtures.fixture(arguments: [
            "AstroTool",
            "-UITestFixtureRoot", fixtureContainer.path,
            "-UITestAppSupport", supportContainer.path,
        ])

        #expect(fixture != nil)
    }

    @Test("The exact XCUITest runner container temporary path is accepted")
    func acceptsXCUITestRunnerContainerTemporaryPath() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent("com.astrotool.app.UITests.xctrunner", isDirectory: true)
            .appendingPathComponent("Data/tmp", isDirectory: true)
            .appendingPathComponent("AstroTool-V2-UI-Fixture-fake", isDirectory: true)

        try refuseRealLibrary(path)
    }

    @Test("Named private temporary roots work across process TMPDIR boundaries")
    func acceptsNamedPrivateTemporaryRoots() throws {
        let runID = UUID().uuidString
        let fixtureContainer = URL(
            fileURLWithPath: "/private/tmp/AstroTool-V2-UI-Fixture-\(runID)",
            isDirectory: true
        )
        let supportContainer = URL(
            fileURLWithPath: "/private/tmp/AstroTool-V2-UI-Support-\(runID)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixtureContainer)
            try? FileManager.default.removeItem(at: supportContainer)
        }

        let optionalFixture = try V2PreviewFixtures.fixture(arguments: [
            "AstroTool",
            "-UITestFixtureRoot", fixtureContainer.path,
            "-UITestAppSupport", supportContainer.path,
        ])
        let fixture = try #require(optionalFixture)

        #expect(fixture.libraryRoot.path.contains(fixtureContainer.lastPathComponent))
        #expect(fixture.libraryRoot.lastPathComponent == "DemoLibrary")
        #expect(fixture.applicationSupport.path.contains(supportContainer.lastPathComponent))
        #expect(fixture.applicationSupport.lastPathComponent == "ApplicationSupport")
        #expect(FileManager.default.fileExists(atPath: fixture.libraryRoot.path))
    }

    @Test("Private temporary paths without the UI fixture prefix are refused")
    func rejectsUnprefixedPrivateTemporaryPath() {
        let path = URL(
            fileURLWithPath: "/private/tmp/Untrusted-AstroTool-Fixture-\(UUID().uuidString)",
            isDirectory: true
        )

        #expect(throws: V2UITestFixtureError.self) {
            try refuseRealLibrary(path)
        }
    }

    @Test("Lookalike macOS temporary structures are refused component by component")
    func rejectsLookalikeMacOSTemporaryStructures() {
        let paths = [
            "/private/var/folders/toolong/opaque/T/AstroTool-V2-UI-Fixture-fake",
            "/private/var/folders/ab/opaque/C/AstroTool-V2-UI-Fixture-fake",
            "/private/var/folders/ab/opaque/T/Not-AstroTool/AstroTool-V2-UI-Fixture-fake",
            "/private/var/folders/ab/opaque/AstroTool-V2-UI-Fixture-fake/T",
        ]

        for path in paths {
            #expect(throws: V2UITestFixtureError.self) {
                try refuseRealLibrary(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
    }

    @Test("Lookalike XCUITest container paths are refused component by component")
    func rejectsLookalikeXCUITestContainerPaths() {
        let containerRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
        let paths = [
            "wrong.bundle.UITests.xctrunner/Data/tmp/AstroTool-V2-UI-Fixture-fake",
            "com.astrotool.app.UITests.xctrunner/tmp/AstroTool-V2-UI-Fixture-fake",
            "com.astrotool.app.UITests.xctrunner/Data/tmp/untrusted/AstroTool-V2-UI-Fixture-fake",
            "com.astrotool.app.UITests.xctrunner/Data/tmp/AstroTool-V2-UI-Fixture-parent/AstroTool-V2-UI-Fixture-child",
        ]

        for path in paths {
            #expect(throws: V2UITestFixtureError.self) {
                try refuseRealLibrary(containerRoot.appendingPathComponent(path, isDirectory: true))
            }
        }
    }

    @Test("A fixture-prefixed temporary symlink cannot escape to a home library")
    func rejectsSymlinkEscape() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-V2-UI-Fixture-Symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let link = container.appendingPathComponent("Escape", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Astro", isDirectory: true)
        )

        #expect(throws: V2UITestFixtureError.self) {
            try refuseRealLibrary(link.appendingPathComponent("DemoLibrary", isDirectory: true))
        }
    }
}

private struct FixtureRacePaths {
    let fixtureContainer: URL
    let supportContainer: URL
    let parkedFixtureContainer: URL
    let parkedSupportContainer: URL
    let realLibraryTarget: URL
    let realSupportTarget: URL

    var arguments: [String] {
        [
            "AstroTool",
            "-UITestFixtureRoot", fixtureContainer.path,
            "-UITestAppSupport", supportContainer.path,
        ]
    }

    static func make(fileManager: FileManager = .default) throws -> Self {
        let temporaryRoot = fileManager.temporaryDirectory
        let runID = UUID().uuidString
        let fixtureContainer = temporaryRoot.appendingPathComponent(
            "AstroTool-V2-UI-Fixture-Race-\(runID)",
            isDirectory: true
        )
        let supportContainer = temporaryRoot.appendingPathComponent(
            "AstroTool-V2-UI-Support-Race-\(runID)",
            isDirectory: true
        )
        let realLibraryTarget = temporaryRoot.appendingPathComponent(
            "OutsideFixtureTarget-\(runID)",
            isDirectory: true
        )
        let realSupportTarget = temporaryRoot.appendingPathComponent(
            "OutsideSupportTarget-\(runID)",
            isDirectory: true
        )
        for url in [fixtureContainer, supportContainer, realLibraryTarget, realSupportTarget] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
        return Self(
            fixtureContainer: fixtureContainer,
            supportContainer: supportContainer,
            parkedFixtureContainer: temporaryRoot.appendingPathComponent(
                "ParkedFixture-\(runID)",
                isDirectory: true
            ),
            parkedSupportContainer: temporaryRoot.appendingPathComponent(
                "ParkedSupport-\(runID)",
                isDirectory: true
            ),
            realLibraryTarget: realLibraryTarget,
            realSupportTarget: realSupportTarget
        )
    }

    func remove(fileManager: FileManager = .default) {
        for url in [
            fixtureContainer,
            supportContainer,
            parkedFixtureContainer,
            parkedSupportContainer,
            realLibraryTarget,
            realSupportTarget,
        ] {
            try? fileManager.removeItem(at: url)
        }
    }
}
