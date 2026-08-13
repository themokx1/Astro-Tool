import AstroApplication
import SwiftUI

public struct FrameInspector: View {
    public let decision: FrameDecisionRecord
    public let requestArchive: () -> Void

    public init(decision: FrameDecisionRecord, requestArchive: @escaping () -> Void) {
        self.decision = decision
        self.requestArchive = requestArchive
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
            Section("File action") {
                Button("Move to Archive…", systemImage: "archivebox", action: requestArchive)
                    .disabled(decision.verdict != .rejected)
                Text("Archive is a separate, previewed file move. Rejecting alone never moves the source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("v2.review.frame-inspector")
    }

    private var fileName: String {
        URL(fileURLWithPath: decision.relativePath).lastPathComponent
    }
}
