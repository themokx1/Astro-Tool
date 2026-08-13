import AstroApplication
import AstroCore
import SwiftUI

public struct PlanningView: View {
    @State private var store = PlanningStore()
    let createProject: () -> Void

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

    private var setupBar: some View {
        GroupBox("Camera and optics") {
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
                    LazyVStack(spacing: 0) {
                        ForEach(store.filteredRecommendations.prefix(80)) { row in
                            RecommendationRow(row: row, createProject: createProject)
                            Divider()
                        }
                    }
                }
            }
            .padding(8)
        }
        .accessibilityIdentifier("v2.planning.recommendations")
    }
}

private struct RecommendationRow: View {
    let row: PlanningRecommendation
    let createProject: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName).font(.headline)
                Text(row.target.kind.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 210, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.fit.label).font(.callout.weight(.medium))
                Text("\((row.frameCoverage * 100), format: .number.precision(.fractionLength(0)))% of short edge")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("≈ \(row.integrationHours, format: .number.precision(.fractionLength(1))) h")
                    .font(.headline.monospacedDigit())
                Text(row.integrationConfidence.rawValue.capitalized)
                    .font(.caption).foregroundStyle(.secondary)
                    .help(row.integrationSource)
            }
            Button("Plan…", action: createProject).buttonStyle(.bordered)
        }
        .padding(.vertical, 9)
    }

    private var displayName: String {
        if let name = row.target.commonNameHU { return "\(row.target.designation) · \(name)" }
        if let name = TargetCatalog.englishName(for: row.target) { return "\(row.target.designation) · \(name)" }
        return row.target.designation
    }
}
