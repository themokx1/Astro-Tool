import SwiftUI

/// R9-T6/B16(a): a "ⓘ" popover explaining a table's computed metrics --
/// what each one means, how it's computed, and (per spec) "mikor hazudik"
/// (when it's unreliable/not computable). Spec's original ask was a
/// per-column-header popover; `Table`'s `TableColumn` only accepts a plain
/// string title on this SDK (no custom header view initializer exists --
/// verified against the SDK, not assumed), so this is one button per table
/// listing every one of that table's computed-metric columns instead of
/// one button each. Same information, one click away either way.
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
            .frame(width: 320, height: 360)
        }
    }
}
