import AstroApplication
import SwiftUI

public struct SeriesInspector: View {
    public let snapshot: ReviewSeriesSnapshot
    public let assignFilter: (EquipmentFilter) -> Void
    @State private var settings = SettingsStore()
    @State private var manufacturer = ""
    @State private var model = ""
    @State private var newFilterPassband = EquipmentFilterPassband.unknown
    @State private var filterError: String?

    public init(snapshot: ReviewSeriesSnapshot, assignFilter: @escaping (EquipmentFilter) -> Void = { _ in }) {
        self.snapshot = snapshot
        self.assignFilter = assignFilter
    }

    public var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Exposure", value: exposure)
                LabeledContent("Sensor", value: snapshot.series.sensorMode.rawValue.uppercased())
                LabeledContent("Passband", value: passband)
                LabeledContent("Filter", value: snapshot.series.filterName ?? "No filter recorded")
                Menu("Choose Filter…") {
                    if settings.filters.isEmpty { Text("No saved filters") }
                    ForEach(settings.filters) { filter in
                        Button(filterTitle(filter)) { assignFilter(filter) }
                    }
                }
                DisclosureGroup("Add a new filter") {
                    TextField("Manufacturer", text: $manufacturer)
                    TextField("Model", text: $model)
                    Picker("Passband", selection: $newFilterPassband) {
                        ForEach(EquipmentFilterPassband.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if let filterError { Text(filterError).foregroundStyle(.red) }
                    Button("Save and Use") {
                        do {
                            let filter = try settings.createFilter(manufacturer: manufacturer, model: model, passband: newFilterPassband)
                            assignFilter(filter); manufacturer = ""; model = ""; newFilterPassband = .unknown; filterError = nil
                        } catch { filterError = error.localizedDescription }
                    }
                }
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

    private func filterTitle(_ filter: EquipmentFilter) -> String {
        [filter.manufacturer, filter.model].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
