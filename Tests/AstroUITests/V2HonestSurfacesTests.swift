import Foundation
import Testing

/// V2 UI/UX audit (2026-08-14), section 4 "Honesty surfaces" -- four small
/// places where a view told the user something the store/engine behind it
/// contradicted. Follows this repo's established "surface" suite
/// convention (`V2PolishSurfaceTests`, `V2ShellSurfaceTests`): literal
/// source-text assertions rather than rendering the view tree, since these
/// are wiring/vocabulary honesty contracts, not layout contracts.
@Suite("V2 honesty surfaces")
struct V2HonestSurfacesTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: 0. Toolbar workflows that need a library must redirect, not lie.
    //
    // 2026-09-02 first-run audit, fix F: "Import from Card…" and "New
    // Night…" are permanent toolbar controls, so both are reachable with no
    // library open. Their sheet branches both required a root, so with none
    // the if-chain fell through to `V2PresentationPlaceholder` and claimed
    // the workflow "will become available as V2 reaches feature parity" --
    // untrue for two shipped, fully working features.

    @Test("Import from Card and New Night with no library open redirect to opening one")
    func libraryRequiringPresentationsRedirectInsteadOfClaimingUnfinishedParity() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(
            source.contains("} else if presentation == .newNight || presentation == .importCapture {"),
            "both library-requiring routes need an explicit no-library branch before the placeholder"
        )
        #expect(source.contains("struct NoLibraryOpenSheet"))
        #expect(source.contains("No library open"))
        #expect(source.contains("v2.presentation.no-library.choose-library"))
        // The redirect must come BEFORE the fall-through placeholder,
        // otherwise the untrue "feature parity" sentence still wins.
        let redirect = try #require(source.range(of: "} else if presentation == .newNight || presentation == .importCapture {"))
        let placeholder = try #require(source.range(of: "V2PresentationPlaceholder(route: presentation)"))
        #expect(redirect.lowerBound < placeholder.lowerBound)
    }

    // MARK: 1. Planning's "Reference" card must show the user's own baseline.

    @Test("PlanningView's Reference card renders the live PlanningStore baseline, not a hardcoded 10 h/APS-C/f5/mu22")
    func planningReferenceCardIsLive() throws {
        let source = try contents("Sources/AstroUI/Features/Planning/PlanningView.swift")
        #expect(!source.contains(#"value: "10 h""#), "the reference card must not hardcode 10 h -- Settings can change it")
        #expect(!source.contains("APS-C · f/5 · μ 22"), "the reference card must not hardcode the old baseline detail text")
        #expect(source.contains("store.referenceHours"))
        #expect(source.contains("store.referenceFocalRatio"))
        #expect(source.contains("store.referenceSurfaceBrightness"))
    }

    // MARK: 2. Library must not claim read-only access unconditionally.

    @Test("The archive page never hardcodes an unconditional Read-only claim; the write-capable pages it links to reflect the real access mode instead")
    func libraryAccessLabelReflectsWriteMode() throws {
        // Task 10: `LibraryView` (and its own unconditional-label fix from
        // the 2026-08-14 audit) is deleted -- `ArchiveView` is its
        // replacement, but by its own explicit design (see its `accessMode`
        // doc comment) it renders no access-mode badge of its own at all:
        // every action it performs directly is read-only regardless of
        // `accessMode`, and the write-capable actions it links to (Cleanup
        // Preview, Organize One Session) already show their own honest
        // access-mode state on their own pages. This keeps the ORIGINAL
        // honesty contract -- no unconditional "Read-only access" lie --
        // while checking it where the claim can actually be made now.
        let archive = try contents("Sources/AstroUI/Features/Archive/ArchiveView.swift")
        #expect(
            !archive.contains(#"Label("Read-only access", systemImage: "lock.shield").foregroundStyle(.green)"#),
            "ArchiveView must not hardcode an unconditional Read-only claim"
        )
        let cleanup = try contents("Sources/AstroUI/Features/Library/CleanupPreviewView.swift")
        #expect(cleanup.contains(".mutationEnabled"))
        #expect(cleanup.contains("Requires write access"), "the write-capable page this page links to must state the real access mode honestly")
    }

    // MARK: 3. Integrity findings must not blanket-claim "no action needed".

    @Test("HealthView gives non-healthy integrity findings honest restore-from-backup guidance")
    func integrityFindingsGetHonestGuidance() throws {
        let source = try contents("Sources/AstroUI/Features/Library/HealthView.swift")
        #expect(source.contains("Restore from backup") || source.contains("restore from backup"))
        // The old code returned "No action needed"/"No action required" for
        // EVERY `.integrity` item regardless of severity -- it must now be
        // conditioned on severity, since a real checksum-mismatch finding
        // (severity != .healthy) is exactly the case `VerifyIntegritySheet`
        // (same file) says means "restore from backup".
        #expect(source.contains("severity == .healthy"), "the integrity guidance must branch on severity, not blanket-apply to the whole category")
    }

    // MARK: 4. Home's night-context rail must not be decorative fake geometry.

    @Test("HomeView's night context rail is driven by real data, not fixed fractions and static labels")
    func homeNightContextRailIsNotFakeGeometry() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(!source.contains("proxy.size.width * 0.58"), "the old fixed observation-window fraction must be gone")
        #expect(!source.contains("proxy.size.width * 0.21"), "the old fixed offset fraction must be gone")
        #expect(!source.contains("proxy.size.width * 0.495"), "the old fixed \"now\" marker fraction must be gone")
        #expect(source.contains("context.isConfigured"), "the rail must render a distinct, honest state when no site is configured")
    }

    @Test("HomeStore never fabricates dusk/dawn/observation-window labels -- NightContext carries a real isConfigured flag")
    func homeSnapshotNightContextIsHonestByDefault() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeStore.swift")
        #expect(source.contains("isConfigured"))
    }

    // MARK: 5. FrameInspector must not offer an archive move nothing performs.

    @Test("No surface offers an archive move the app cannot perform")
    func noFalseArchivePromise() throws {
        for file in ["Sources/AstroUI/Inspector/FrameInspector.swift",
                     "Sources/AstroUI/Features/Review/ReviewWorkspace.swift"] {
            let source = try contents(file)
            #expect(!source.contains("Move to Archive"), "\(file) still offers a move nothing implements")
            #expect(!source.contains("ArchivePreviewSheet"), "\(file) still presents the dead-end sheet")
        }
    }

    // MARK: 6. Task 14 (owner screenshot) -- error surfaces must name the
    // real problem and never a raw Swift error type/case index.

    @Test("No error surface shows the user a raw Swift error type or case index")
    func errorSurfacesNeverShowRawSwiftErrors() throws {
        for file in ["FirstScanSummaryView.swift", "FirstScanView.swift", "LibraryWelcomeView.swift"] {
            let source = try contents("Sources/AstroUI/Onboarding/\(file)")
            #expect(
                !source.contains("error.localizedDescription)"),
                "\(file) interpolates a raw error description into user-facing copy"
            )
        }
    }

    @Test("The onboarding access-problem dialog derives its buttons from the error's recovery, not a fixed Back/Close/Choose-Another set")
    func accessProblemButtonsComeFromRecovery() throws {
        let source = try contents("Sources/AstroUI/Onboarding/LibraryWelcomeView.swift")
        // The old fixed button set: "Back" led to the exact same outcome as
        // "Close" (both just left the sheet's access-problem state with no
        // recovery attempted) -- two buttons, one outcome, two ways to
        // guess wrong. It must be gone.
        #expect(!source.contains(#"Button("Back")"#), "the redundant Back button (same outcome as Close) must be removed")
        #expect(source.contains(#"Button("Close")"#), "Close must remain as the one no-recovery way out")
        // The new buttons are keyed off `AstroErrorRecovery`, not a single
        // "Choose Another Library" applied unconditionally to every error.
        #expect(source.contains("for recovery: AstroErrorRecovery"))
        #expect(source.contains(#"Button("Choose Library Again…")"#))
        #expect(source.contains(#"Button("Try Again")"#))
        #expect(source.contains(#"Button("Choose a Different Library…")"#))
    }
}
