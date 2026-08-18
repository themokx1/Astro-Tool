import Foundation
import Testing

/// W6-E item 6 (live pixel review, 1100pt): the Review workspace's own
/// Accept/Reset/Reject bar sat squeezed between the "Frames" heading and the
/// frame table's own trailing edge -- at the app's own minimum window width,
/// the (longer, Hungarian) button labels truncated to "Elfo…" with no way to
/// read the rest. Fixed with `ViewThatFits`: icon+label first, falling back
/// to icon-only (each button keeps a real accessible label via its own
/// `Label`/`.help`) once there isn't room, rather than truncating mid-word.
/// This repo has no rendering harness for verifying actual pixel widths (see
/// `W3T12SilentFailureSurfaceTests`'s own doc comment for the established
/// literal-source-text convention this follows instead).
@Suite("W6-E Review workspace action bar")
struct W6EReviewActionBarSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Review/ReviewWorkspace.swift"),
            encoding: .utf8
        )
    }

    @Test("The action bar offers an icon+label layout and an icon-only fallback via ViewThatFits, never a fixed-width truncating one")
    func actionBarHasAFitFallback() throws {
        let text = try source()
        #expect(text.contains("ViewThatFits(in: .horizontal)"), "must offer a narrower fallback instead of truncating button text")
        #expect(text.contains(".labelStyle(.titleAndIcon)"))
        #expect(text.contains(".labelStyle(.iconOnly)"))
        // Every button keeps a real accessible label even in icon-only mode.
        #expect(text.contains("Label(\"Accept\", systemImage:"))
        #expect(text.contains("Label(\"Reset\", systemImage:"))
        #expect(text.contains("Label(\"Reject\", systemImage:"))
        #expect(text.contains(".help(\"Accept\")"))
        #expect(text.contains(".help(\"Reset Decision\")"))
        #expect(text.contains(".help(\"Reject\")"))
    }

    @Test("Accept/Reject keep their existing ⌘⇧A/⌘⇧R shortcuts, and Reset gains its own ⌘⇧U")
    func resetGainsItsOwnShortcut() throws {
        let text = try source()
        #expect(text.contains(#".keyboardShortcut("a", modifiers: [.command, .shift])"#))
        #expect(text.contains(#".keyboardShortcut("r", modifiers: [.command, .shift])"#))
        // Reset had no shortcut at all before this fix.
        #expect(text.contains(#".keyboardShortcut("u", modifiers: [.command, .shift])"#), "Reset must get its own shortcut, distinct from Accept/Reject")
    }

    @Test("Every action bar button keeps its own accessibility identifier")
    func accessibilityIdentifiersSurvive() throws {
        let text = try source()
        #expect(text.contains(#"accessibilityIdentifier("v2.review.accept")"#))
        #expect(text.contains(#"accessibilityIdentifier("v2.review.reset")"#))
        #expect(text.contains(#"accessibilityIdentifier("v2.review.reject")"#))
    }
}
