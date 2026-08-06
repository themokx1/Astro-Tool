import AstroCore
import SwiftUI

/// Inline mosaic-panel table for the "Áttekintés" segment (R9-T3/A.3) --
/// same content as `StatsView`'s old `PanelsPopoverButton` popover, just
/// embedded directly on the page instead of behind a click. Only ever shown
/// when `PanelReport.isMosaic` (the caller checks that before instantiating
/// this view, same convention the old popover used).
struct MosaicPanelTable: View {
    let report: PanelReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mozaik — \(report.panels.count) panel").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Panel").bold()
                    Text("Közép RA/Dec").bold()
                    Text("Keret").bold()
                    Text("Integráció").bold()
                    Text("Rot.").bold()
                    Text("Skála").bold()
                }
                .font(.caption)
                ForEach(report.panels, id: \.label) { panel in
                    GridRow {
                        Text(panel.label)
                        Text(String(format: "%.4f / %+.4f", panel.centerRaDeg, panel.centerDecDeg))
                        Text("\(panel.frameCount)")
                        Text(TDFormat.hm(panel.integrationSeconds))
                        Text(panel.rotationDeg.map { String(format: "%.1f°", $0) } ?? "-")
                        Text(panel.pixelScaleArcsec.map { String(format: "%.2f\"/px", $0) } ?? "-")
                    }
                    .font(.caption)
                }
            }

            if report.isUnbalanced {
                Text("⚠️ kiegyenlítetlen mozaik")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
