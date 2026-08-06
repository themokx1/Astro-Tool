import SwiftUI

/// R9-T6/B16(a): a "ⓘ" popover explaining a table's computed metrics --
/// what each one means, how it's computed, and (per spec) "mikor hazudik"
/// (when it's unreliable/not computable). Spec's original ask was a
/// per-column-header popover; `Table`'s `TableColumn` only accepts a plain
/// string title on this SDK (no custom header view initializer exists --
/// verified against the SDK, not assumed), so this is one button per table
/// listing every one of that table's computed-metric columns instead of
/// one button each. Same information, one click away either way.
///
/// R10-B7: file renamed from `InfoHeader.swift` to match the type it
/// actually defines (`git mv`, no behavior change), and the popover grew a
/// "Fogalomtár…" footer link so a reader confused by one metric's own
/// jargon has a path to the full glossary without hunting for the menu
/// bar's "Súgó ▸ Fogalomtár" item.
struct MetricInfoButton: View {
    struct Metric {
        let title: String
        let explanation: String
    }

    let metrics: [Metric]

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .help("A táblázat számított oszlopainak jelentése")
        .popover(isPresented: $showPopover) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(metric.title).font(.subheadline).bold()
                                Text(metric.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                }
                Divider()
                // R10-B7: one click from any per-table metric popover to the
                // full Fogalomtár -- posts the exact same notification the
                // menu bar's own "Súgó ▸ Fogalomtár" item does
                // (`Commands.swift`), observed app-wide by `RootView`
                // (`AstroToolApp.swift`) regardless of which page/popover
                // triggered it.
                Button("Fogalomtár…") {
                    showPopover = false
                    NotificationCenter.default.post(name: .showGlossary, object: nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            }
            .frame(width: 320, height: 360)
        }
    }
}
