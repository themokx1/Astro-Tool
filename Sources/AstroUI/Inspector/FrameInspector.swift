import AstroApplication
import SwiftUI

public struct FrameInspector: View {
    public let decision: FrameDecisionRecord

    public init(decision: FrameDecisionRecord) {
        self.decision = decision
    }

    public var body: some View {
        Form {
            Section("Frame") {
                LabeledContent("File", value: fileName)
                LabeledContent("Source path", value: decision.relativePath)
            }
            Section("Decision") {
                // V2 localization sweep (W3-13): both rows used to render a
                // plain `String` value (`verdict.rawValue.capitalized`, and
                // a ternary of two literals) through `LabeledContent`'s
                // verbatim `value:` parameter -- neither ever localized.
                // `FrameVerdict.displayLabel`/`FrameDecisionRecord
                // .stackInclusionLabel` (`ReviewWorkspace.swift`, shared with
                // that screen's own frame table) fix the same leak class
                // here via the content-closure initializer.
                LabeledContent("Verdict") { Text(decision.verdict.displayLabel) }
                LabeledContent("Stack inclusion") { Text(decision.stackInclusionLabel) }
            }
        }
        .formStyle(.grouped)
        // Task 6 (2026-08-17, Liquid Glass): same treatment as
        // `SeriesInspector` -- see its own comment. Used only as
        // `ReviewWorkspace`'s own embedded inspector pane, never as an
        // ancestor of that screen's `List`/`Table`.
        .glassEffect(.regular, in: ConcentricRectangle())
        .accessibilityIdentifier("v2.review.frame-inspector")
    }

    private var fileName: String {
        URL(fileURLWithPath: decision.relativePath).lastPathComponent
    }
}
