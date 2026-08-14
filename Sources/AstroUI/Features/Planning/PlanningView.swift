import AstroApplication
import AstroCore
import SwiftUI

public struct PlanningView: View {
    @State private var store = PlanningStore()
    @State private var selectedTargetID: String?
    let createProject: (String) -> Void

    public var body: some View {
        WorkspacePage(
            eyebrow: "Next clear night",
            title: "Planning",
            subtitle: "Choose a setup first, then compare honest framing and integration estimates."
        ) {
            setupBar
            baselineCard
            recommendationList
        }
        .navigationTitle("Planning")
        .accessibilityLabel("Planning")
        .accessibilityIdentifier("v2.detail.planning")
    }

    /// Backs the "Camera and optics" header's ⓘ button.
    private static let setupMetricInfo: [MetricInfoButton.Metric] = [
        .init(title: "Field of view (FOV)", explanation: "The area of sky your sensor and optics cover, in degrees wide by degrees tall.", glossaryTerm: "Field of view (FOV) / framing fit"),
        .init(title: "Focal length", explanation: "The optical system's focal length in millimeters. A longer focal length gives a narrower, more magnified field of view."),
        .init(title: "Integration", explanation: "The estimated total exposure time needed for a clean result at this setup's framing and sky conditions.", glossaryTerm: "Integration (gross vs. real)"),
    ]

    private var setupBar: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Setup", selection: $store.selectedSetupID) {
                        ForEach(store.setups) { setup in Text(setup.name).tag(setup.id) }
                    }
                    .accessibilityIdentifier("v2.planning.setup")
                    Spacer()
                    if let fov = store.fieldOfView {
                        Text("\(fov.widthDeg, format: .number.precision(.fractionLength(1)))° × \(fov.heightDeg, format: .number.precision(.fractionLength(1)))°")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if store.selectedSetup.isZoom {
                    HStack {
                        Text("\(store.selectedSetup.focalLengthMinMM, format: .number) mm").font(.caption).foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { store.focalLength },
                                set: { value in store.setFocalLength(value) }
                            ),
                            in: store.selectedSetup.focalLengthMinMM...store.selectedSetup.focalLengthMaxMM,
                            step: 1
                        )
                        Text("\(store.focalLength, format: .number.precision(.fractionLength(0))) mm")
                            .monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    .accessibilityIdentifier("v2.planning.focal-length")
                }
            }
            .padding(8)
        } label: {
            HStack(spacing: 6) {
                Text("Camera and optics")
                MetricInfoButton(metrics: Self.setupMetricInfo)
            }
        }
    }

    private var baselineCard: some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            MetricCard(title: "Reference", value: "10 h", detail: "APS-C · f/5 · μ 22", systemImage: "timer")
            MetricCard(
                title: "Focal length", value: "\(store.focalLength.formatted(.number.precision(.fractionLength(0)))) mm",
                detail: store.selectedSetup.cameraName, systemImage: "camera.aperture"
            )
            MetricCard(
                title: "Useful matches", value: "\(store.filteredRecommendations.count)",
                detail: "Tiny targets ranked lower", systemImage: "scope"
            )
        }
        .accessibilityIdentifier("v2.planning.integration")
    }

    private var recommendationList: some View {
        GroupBox("Target recommendations") {
            VStack(spacing: 12) {
                HStack {
                    TextField("Catalog number, English or Hungarian name", text: $store.searchText)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Useful framing only", isOn: $store.usefulFramingOnly)
                        .toggleStyle(.checkbox)
                }
                if store.filteredRecommendations.isEmpty {
                    ContentUnavailableView.search(text: store.searchText)
                        .frame(minHeight: 220)
                } else {
                    Table(store.filteredRecommendations, selection: $selectedTargetID) {
                        TableColumn("Target") { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(row)).font(.headline)
                                Text(row.target.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        TableColumn("Framing") { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.fit.label).fontWeight(.medium)
                                Text("\((row.frameCoverage * 100), format: .number.precision(.fractionLength(0)))% of short edge")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 145, ideal: 180)
                        TableColumn("Integration") { row in
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("≈ \(row.integrationHours, format: .number.precision(.fractionLength(1))) h")
                                    .font(.headline.monospacedDigit())
                                Text(row.integrationConfidence.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 105, ideal: 125)
                    }
                    .frame(minHeight: 300)
                    .contextMenu(forSelectionType: String.self) { targetIDs in
                        if let row = store.filteredRecommendations.first(where: { targetIDs.contains($0.id) }) {
                            Button("Plan Selected") { createProject(row.target.designation) }
                        }
                    } primaryAction: { targetIDs in
                        if let row = store.filteredRecommendations.first(where: { targetIDs.contains($0.id) }) {
                            createProject(row.target.designation)
                        }
                    }
                }
            }
            .padding(8)
        }
        .accessibilityIdentifier("v2.planning.recommendations")
    }

    private func displayName(_ row: PlanningRecommendation) -> String {
        if let name = row.target.commonNameHU { return "\(row.target.designation) · \(name)" }
        if let name = TargetCatalog.englishName(for: row.target) { return "\(row.target.designation) · \(name)" }
        return row.target.designation
    }
}
