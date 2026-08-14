import SwiftUI

/// Help ▸ Folder Structure -- the library folder layout AstroTool expects,
/// as a monospaced tree. Content mirrors V1's `FolderStructureHelpSheet`
/// (itself kept in sync with the website's tutorial), translated to English
/// rather than transliterated -- the V2 UI is English throughout.
public struct FolderStructureHelpView: View {
    public let dismiss: () -> Void

    public static let treeText = """
    <ROOT>/
    ├── sessions/<TARGET>/<YYYY-MM-DD>/
    │   ├── lights/   flats/   darks/   biases/
    │   └── README.txt              # hand-filled note: Bortle, SQM, seeing…
    ├── stacks/<TARGET>/<YYYY-MM-DD>/
    ├── processed/<TARGET>/<YYYY-MM-DD>/
    └── calibration_library/
        ├── darks/<exp>sec_<temp>deg/   # e.g. 300sec_-10deg
        ├── flats/
        └── biases/
    """

    public init(dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Expected folder structure").font(.headline)

            ScrollView([.horizontal, .vertical]) {
                Text(Self.treeText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("• sessions — the raw, original captures. Nothing here is ever overwritten or deleted.")
                Text("• stacks — intermediate stacked results, always reproducible from sessions.")
                Text("• processed — final, post-processed images.")
                Text("• calibration_library — reusable master dark/flat/bias frames.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Close", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
        .accessibilityIdentifier("v2.help.folder-structure")
    }
}
