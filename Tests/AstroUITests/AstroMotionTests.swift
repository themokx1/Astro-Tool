import Foundation
import SwiftUI
import Testing

@testable import AstroUI

/// Wave 2 Task 8 (motion pass): gates for the app's one motion vocabulary,
/// `AstroMotion` (`Sources/AstroUI/DesignSystem/AstroMotion.swift`).
///
/// The source-scan gate (`noAnimationCallSiteInFeaturesBypassesTheHelper`)
/// was proven red before it was proven green: run once with a deliberately
/// injected `.animation(.spring(), value: 1)` line added to
/// `WorkspaceComponents.swift`, it failed and named that exact file; run
/// again after reverting the injection, it passed. What remains here is the
/// passing (green) state plus the two reduce-motion unit tests, which are
/// real, not source-text proxies: they call `AstroMotion` directly and
/// assert it resolves to its identity case under Reduce Motion.
@Suite("AstroMotion (Wave 2 Task 8)")
struct AstroMotionTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: (a) Reduce Motion resolves every helper to its identity case.

    @Test("AstroMotion.animation resolves to nil under Reduce Motion, and to the given animation otherwise")
    func animationResolvesToNilUnderReduceMotion() {
        #expect(AstroMotion.animation(reduceMotion: true) == nil)
        #expect(AstroMotion.animation(reduceMotion: false) == AstroMotion.curve)

        let custom = Animation.spring(response: 0.4, dampingFraction: 0.8)
        #expect(AstroMotion.animation(custom, reduceMotion: true) == nil)
        #expect(AstroMotion.animation(custom, reduceMotion: false) == custom)
    }

    @Test("AstroMotion's content-swap style resolves to .identity under Reduce Motion")
    func contentSwapStyleResolvesToIdentityUnderReduceMotion() {
        #expect(AstroMotion.contentSwapStyle(reduceMotion: true) == .identity)
        #expect(AstroMotion.contentSwapStyle(reduceMotion: false) == .fadeAndRise)
    }

    @Test("AstroMotion's glass-morph style resolves to .identity under Reduce Motion")
    func glassMorphStyleResolvesToIdentityUnderReduceMotion() {
        #expect(AstroMotion.glassMorphStyle(reduceMotion: true) == .identity)
        #expect(AstroMotion.glassMorphStyle(reduceMotion: false) == .matchedGeometry)
    }

    // MARK: (b) No Features/ call site bypasses the helper.

    /// One narrowly-scoped, documented exception: `ArchiveStripView.swift`'s
    /// own `.animation(reduceMotion ? nil : .snappy(duration: 0.45), value:
    /// reclaimFraction)` (line ~105) predates this task, is already
    /// correctly Reduce-Motion-safe by hand, and sits under
    /// `Sources/AstroUI/Features/Archive` -- outside this task's file scope
    /// (`AppRoute.swift`/`V2RootView.swift`/`DesignSystem/`/
    /// `WorkspaceComponents.swift`/`InspectorView.swift`) to migrate onto
    /// the shared helper. Exempted the same way
    /// `V2PolishSurfaceTests.colorLiteralExemptFiles` exempts a pre-existing
    /// file pending its own migration, not because the pattern is
    /// acceptable going forward.
    private static let motionGateExemptFiles: Set<String> = ["ArchiveStripView.swift"]

    /// Strips `//` line comments, string-literal-aware, so a doc comment
    /// that names `.animation(`/`withAnimation(` while explaining what NOT
    /// to write (as this file's own header does) never trips the gate.
    /// Same algorithm as `V2PolishSurfaceTests.removingLineComments`.
    private static func removingLineComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var i = source.startIndex
        var inLineComment = false
        var inString = false
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            if inLineComment {
                if c == "\n" { inLineComment = false; result.append(c) }
                i = next
                continue
            }
            if inString {
                result.append(c)
                if c == "\\", next < source.endIndex {
                    result.append(source[next])
                    i = source.index(after: next)
                    continue
                }
                if c == "\"" { inString = false }
                i = next
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                i = next
                continue
            }
            if c == "/", next < source.endIndex, source[next] == "/" {
                inLineComment = true
                i = source.index(after: next)
                continue
            }
            result.append(c)
            i = next
        }
        return result
    }

    @Test("No file under Sources/AstroUI/Features calls withAnimation(/.animation( directly -- every animation routes through AstroMotion/astroAnimation")
    func noAnimationCallSiteInFeaturesBypassesTheHelper() throws {
        let root = repositoryRoot.appendingPathComponent("Sources/AstroUI/Features")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(root.path)")
            return
        }
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if Self.motionGateExemptFiles.contains(url.lastPathComponent) { continue }
            guard let rawText = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let text = Self.removingLineComments(rawText)
            if text.contains("withAnimation(") || text.contains(".animation(") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "Raw withAnimation(/.animation( call sites (bypassing AstroMotion) in: \(offenders.joined(separator: ", "))")
    }

    // MARK: (c) WorkspaceComponents adoptions route through AstroMotion, never a raw ternary.

    @Test("WorkspaceComponents' glass adoptions go through AstroMotion, not a raw .glassEffectTransition( call")
    func workspaceComponentsGlassAdoptionsUseTheSharedHelper() throws {
        let source = try contents("Sources/AstroUI/Features/Workspace/WorkspaceComponents.swift")
        #expect(source.contains("astroGlassMorph("), "WorkspaceComponents.swift should adopt glass morphing via the shared astroGlassMorph(...) helper")
        #expect(!source.contains(".glassEffectTransition("), "WorkspaceComponents.swift should not call .glassEffectTransition( directly -- go through astroGlassMorph(...)")
    }
}
