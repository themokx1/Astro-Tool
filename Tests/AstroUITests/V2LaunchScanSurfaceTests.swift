import Foundation
import Testing

/// Task 2 (V2 UI/UX audit section 2.2): source-level surface assertions for
/// `V2RootView` -- the behavior itself is covered by `LibraryLaunchScanTests`
/// (`OnboardingStore.openAndScan(_:through:)`/`restoreSavedLibrary(through:)`)
/// and `OperationHostTests` (`outcome(of:)`/`errorMessage(for:)`); these
/// confirm the shell actually WIRES that behavior in rather than leaving it
/// unreachable, the same string-assertion style `V2SettingsTests` already
/// uses for this file.
@Suite("V2 launch-scan and access-problem surface")
struct V2LaunchScanSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The launch-time restore is routed through OperationHost, not the raw unrouted restoreSavedLibrary()")
    func launchRestoreGoesThroughOperationHost() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("@AppStorage(\"v2.library.scanOnOpen\")"))
        #expect(source.contains("else if scanOnOpen"))
        #expect(source.contains("restoreSavedLibrary(through: operationHost)"))
    }

    @Test("The post-scan library-preparation pipeline (materializer, projectsStore/nightsStore open, homeStore configure) is routed through OperationHost")
    func prepareLibraryGoesThroughOperationHost() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("private func prepareLibrary(root: URL) async"))
        #expect(source.contains("OperationKind.loadHome(library:"))
        #expect(source.contains("operationHost.run("))
        #expect(source.contains("ScanWorkflowMaterializer.materializeProductionLibrary(rootURL: root)"))
        #expect(source.contains("operationHost.outcome(of: id)"))
    }

    @Test("An access-problem phase is rendered in the main shell, with Retry and Choose Another Library actions")
    func accessProblemIsRenderedInTheShell() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("onboardingStore.phase.accessProblemMessage"))
        #expect(source.contains("struct LibraryAccessProblemBanner"))
        #expect(source.contains("v2.shell.access-problem"))
        #expect(source.contains("v2.shell.access-problem.retry"))
        #expect(source.contains("v2.shell.access-problem.choose-another-library"))
    }

    @Test("The library-preparation-failed alert offers Retry and Choose Another Library, not just OK")
    func libraryPreparationAlertOffersRecovery() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        guard let alertStart = source.range(of: "\"Library preparation needs attention\",") else {
            Issue.record("could not find the library-preparation alert")
            return
        }
        let alertBody = String(source[alertStart.lowerBound...].prefix(1200))
        #expect(alertBody.contains("Button(\"Retry\")"))
        #expect(alertBody.contains("retryLibraryPreparation()"))
        #expect(alertBody.contains("Button(\"Choose Another Library…\")"))
        #expect(!alertBody.contains(#"Button("OK") { libraryPreparationError = nil }"#))
    }
}
