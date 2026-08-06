import SwiftUI

/// The expected library folder layout, as a monospace tree -- shown from
/// both `WelcomeView`'s "Milyen mappastruktúrát vár?" link and (indirectly,
/// via the same text) `FirstScanView`'s checklist explanation. Text mirrors
/// `docs/tutorial.html`'s "1. A könyvtár felépítése" section so the app and
/// the website never describe two different layouts.
struct FolderStructureHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    static let treeText = """
    <ROOT>/
    ├── sessions/<CÉLPONT>/<ÉÉÉÉ-HH-NN>/
    │   ├── lights/   flats/   darks/   biases/
    │   └── README.txt              # kézzel kitöltött jegyzet: Bortle, SQM, seeing…
    ├── stacks/<CÉLPONT>/<ÉÉÉÉ-HH-NN>/
    ├── processed/<CÉLPONT>/<ÉÉÉÉ-HH-NN>/
    └── calibration_library/
        ├── darks/<exp>sec_<temp>deg/   # pl. 300sec_-10deg
        ├── flats/
        └── biases/
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Elvárt mappastruktúra").font(.headline)

            ScrollView([.horizontal, .vertical]) {
                Text(Self.treeText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("• sessions — a nyers, eredeti felvételek. Ide semmit sosem írunk felül és sosem törlünk.")
                Text("• stacks — a stackelt köztes eredmények, bármikor újra elő tudod állítani a sessions-ből.")
                Text("• processed — a végleges, feldolgozott (post-processed) képek.")
                Text("• calibration_library — újrafelhasználható master dark/flat/bias keretek.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 380)
    }
}
