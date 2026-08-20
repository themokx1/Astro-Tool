import AstroApplication
import AstroCore
import Charts
import SwiftUI

/// The selected Planning row's altitude across the planned night -- restores
/// V1's `SkyChartView` natively, over `SkyPathQuery`'s samples rather than a
/// second astrophysics implementation. Follows `InsightsView`'s own Swift
/// Charts conventions (a plain `Chart` builder, `AstroTokens` colors).
struct SkyPathChart: View {
    let result: SkyPathResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(result.samples, id: \.time) { sample in
                    LineMark(x: .value("Time", sample.time), y: .value("Altitude", sample.altitudeDeg))
                        .foregroundStyle(AstroTokens.Color.accent)
                        .interpolationMethod(.catmullRom)
                }
                RuleMark(y: .value("Imaging threshold", result.minAltitudeDeg))
                    .foregroundStyle(AstroTokens.Color.attention)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("\(result.minAltitudeDeg, format: .number.precision(.fractionLength(0)))° min")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                if let culminationTime = result.culminationTime {
                    PointMark(x: .value("Time", culminationTime), y: .value("Altitude", result.maxAltitudeDeg))
                        .foregroundStyle(AstroTokens.Color.accent)
                        .symbolSize(90)
                        .annotation(position: .top) {
                            Text("Culm. \(result.maxAltitudeDeg, format: .number.precision(.fractionLength(0)))°")
                                .font(.caption2.weight(.medium))
                        }
                }
            }
            .chartYScale(domain: 0...90)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxisLabel("Altitude (°)")
            .frame(minHeight: 190)

            if let moonSeparationDeg = result.moonSeparationDeg {
                Text("Moon \(moonSeparationDeg, format: .number.precision(.fractionLength(0)))° away tonight")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("v2.planning.sky-path")
    }
}
