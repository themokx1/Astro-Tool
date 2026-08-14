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

    @Test("LibraryView reflects the real access mode instead of an unconditional Read-only access label")
    func libraryAccessLabelReflectsWriteMode() throws {
        let source = try contents("Sources/AstroUI/Features/Library/LibraryView.swift")
        #expect(
            !source.contains(#"Label("Read-only access", systemImage: "lock.shield").foregroundStyle(.green)"#),
            "the old unconditional label must be gone -- it lied whenever mutation was enabled"
        )
        #expect(source.contains("enableWriteOperations"), "LibraryView must read the same write-mode flag HealthView/CalibrationView use")
        #expect(source.contains(".mutationEnabled"))
        #expect(source.contains("\"Writable\""))
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
}
