import AstroApplication
import SwiftUI

public struct SeriesInspector: View {
    public let snapshot: ReviewSeriesSnapshot

    public init(snapshot: ReviewSeriesSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Exposure", value: exposure)
                LabeledContent("Sensor", value: snapshot.series.sensorMode.rawValue.uppercased())
                LabeledContent("Passband", value: passband)
                LabeledContent("Filter", value: snapshot.series.filterName ?? "No filter recorded")
            }
            Section("Setup") {
                LabeledContent("Equipment", value: snapshot.series.setupDescriptor)
                LabeledContent("Binning", value: snapshot.series.binning)
                if let gain = snapshot.series.gain {
                    LabeledContent("Gain", value: gain.formatted(.number.precision(.fractionLength(0...1))))
                }
                if let offset = snapshot.series.offset {
                    LabeledContent("Offset", value: offset.formatted(.number.precision(.fractionLength(0...1))))
                }
            }
            Section("Review") {
                LabeledContent("Accepted", value: "\(snapshot.acceptedCount)")
                LabeledContent("Rejected", value: "\(snapshot.rejectedCount)")
                LabeledContent("Undecided", value: "\(snapshot.undecidedCount)")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("v2.review.inspector")
    }

    private var exposure: String {
        "\(snapshot.series.exposureSeconds.formatted(.number.precision(.fractionLength(0...2)))) s"
    }

    private var passband: String {
        snapshot.series.passband.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
