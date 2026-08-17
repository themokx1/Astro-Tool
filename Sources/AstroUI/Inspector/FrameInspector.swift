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
                LabeledContent("Verdict", value: decision.verdict.rawValue.capitalized)
                LabeledContent("Stack inclusion", value: decision.logicallyExcluded ? "Excluded" : "Included")
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
