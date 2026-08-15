import AstroApplication
import AstroCore
import SwiftUI

public struct PlanningView: View {
    @State private var store = PlanningStore()
    @State private var selectedTargetID: String?
    /// Mirrors `PlanningStore.sortOrder`. The table needs a `Binding`, but the
    /// actual re-sorting happens in the store's cached recompute — never in
    /// `body`, where sorting the whole catalog every layout pass is exactly
    /// what froze this page before.
    @State private var sortOrder: [KeyPathComparator<PlanningRecommendation>] = [
        KeyPathComparator(\PlanningRecommendation.planningScore, order: .reverse)
    ]
    let rootURL: URL?
    let createProject: (String) -> Void

    public init(rootURL: URL?, createProject: @escaping (String) -> Void) {
        self.rootURL = rootURL
        self.createProject = createProject
    }

    public var body: some View {
        WorkspaceTablePage(
            eyebrow: "Next clear night",
            title: "Planning",
            subtitle: "Choose a setup first, then compare honest framing and integration estimates."
        ) {
            setupBar
            baselineCard
            filterBar
        } table: {
            recommendationList
        }
        .navigationTitle("Planning")
        .accessibilityLabel("Planning")
        .accessibilityIdentifier("v2.detail.planning")
        .task { store.activate() }
        .task(id: rootURL) { store.setRootURL(rootURL) }
        .onChange(of: sortOrder) { _, newValue in store.setSortOrder(newValue) }
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
            MetricCard(
                title: "Reference",
                value: "\(store.referenceHours.formatted(.number.precision(.fractionLength(0...1)))) h",
                detail: "f/\(store.referenceFocalRatio.formatted(.number.precision(.fractionLength(0...1)))) · μ \(store.referenceSurfaceBrightness.formatted(.number.precision(.fractionLength(0...1))))",
                systemImage: "timer"
            )
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

    /// The planner's fixed filter and action bar. It lives in
    /// `WorkspaceTablePage`'s non-scrolling toolbar slot, so it stays put
    /// while the target table scrolls underneath it.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            HStack(spacing: AstroTokens.Spacing.standard) {
                DatePicker(
                    "Night",
                    selection: Binding(
                        get: { store.planningDate ?? Date() },
                        set: { store.setPlanningDate($0) }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.field)
                .fixedSize()
                .accessibilityIdentifier("v2.planning.date")
                .help("Plan for a different night. Ranking is computed for that night's sky.")

                Button("Today") { store.setPlanningDate(Date()) }
                    .disabled(store.isPlanningToday())
                    .accessibilityIdentifier("v2.planning.today")
                    .help("Go back to planning for tonight.")

                Divider().frame(height: 16)

                Toggle(
                    "Hide targets that aren't photographable",
                    isOn: Binding(
                        get: { !store.showLowAltitudeTargets },
                        set: { store.showLowAltitudeTargets = !$0 }
                    )
                )
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("v2.planning.hide-unobservable")
                .help("Targets that never clear the imaging altitude on the chosen night.")

                Spacer()

                Button("Plan Project") { planSelectedTarget() }
                    .disabled(selectedTargetID == nil)
                    .accessibilityIdentifier("v2.planning.plan-project")
                    .help("Create a project for the selected target.")
            }
            HStack(spacing: AstroTokens.Spacing.standard) {
                TextField("Catalog number, English or Hungarian name", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("v2.planning.search")
                Toggle("Useful framing only", isOn: $store.usefulFramingOnly)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func planSelectedTarget() {
        guard let selectedTargetID,
              let row = store.filteredRecommendations.first(where: { $0.id == selectedTargetID })
        else { return }
        createProject(row.target.designation)
    }

    private var recommendationList: some View {
        GroupBox("Target recommendations") {
            Group {
                switch store.skyAvailability {
                case .pending where store.recommendations.isEmpty:
                    // The first `refresh()` (kicked off by `PlanningStore.init`)
                    // hasn't landed yet -- an honest "still computing" state,
                    // not a false "no matches" claim (part of the build 20013
                    // crash fix: `recommendations` is now computed off the
                    // main actor, so it is briefly empty on first load).
                    ProgressView("Finding matches…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .noLibrary:
                    // Ranking by tonight's sky needs a resolved site
                    // (`Planner.resolveSite`); no library is open at all, so
                    // there is nothing to rank against and no ranking is
                    // invented -- see `PlanningQuery.site`'s own doc.
                    ContentUnavailableView(
                        "Open a Library to Get Tonight's Ranking",
                        systemImage: "location.slash",
                        description: Text("Planning ranks targets by where they actually are in the sky tonight. Open a library first.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .noSite:
                    ContentUnavailableView(
                        "Set Your Site to Get Tonight's Ranking",
                        systemImage: "location.slash",
                        description: Text("This library has no observing site configured and none could be derived from its FITS headers. Set a site in Settings to rank targets by tonight's sky.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    if store.filteredRecommendations.isEmpty {
                        ContentUnavailableView.search(text: store.searchText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(store.filteredRecommendations, selection: $selectedTargetID, sortOrder: $sortOrder) {
                            TableColumn("Target", value: \.target.designation) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(row)).font(.headline)
                                    Text(row.target.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            TableColumn("Score", value: \.planningScore) { row in
                                Text(row.planningScore, format: .number.precision(.fractionLength(2)))
                                    .font(.headline.monospacedDigit())
                            }
                            .width(min: 62, ideal: 72)
                            TableColumn("Photographable", value: \.photographableFactor) { row in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(percent(row.photographableFactor))
                                        .font(.callout.monospacedDigit()).fontWeight(.medium)
                                    if let visibleHours = row.visibleHours {
                                        Text("\(visibleHours, format: .number.precision(.fractionLength(1))) h")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .width(min: 96, ideal: 112)
                            TableColumn("Frame fill", value: \.frameFillFactor) { row in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(percent(row.frameFillFactor))
                                        .font(.callout.monospacedDigit()).fontWeight(.medium)
                                    Text("\((row.frameCoverage * 100), format: .number.precision(.fractionLength(0)))% of edge")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 90, ideal: 108)
                            TableColumn("Moon", value: \.moonFactor) { row in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(percent(row.moonFactor))
                                        .font(.callout.monospacedDigit()).fontWeight(.medium)
                                    if let separation = row.moonSeparationDeg {
                                        Text("\(separation, format: .number.precision(.fractionLength(0)))° away")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .width(min: 74, ideal: 88)
                            TableColumn("Tonight's sky") { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    if row.isLowAltitude {
                                        Label(row.skyVerdict, systemImage: "exclamationmark.triangle.fill")
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    } else {
                                        Text("\(row.maxAltitudeDeg ?? 0, format: .number.precision(.fractionLength(0)))° max alt")
                                            .fontWeight(.medium)
                                    }
                                    Text(skyDetail(row)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 165, ideal: 200)
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
                                    if let hours = row.integrationHours {
                                        Text("≈ \(hours, format: .number.precision(.fractionLength(1))) h")
                                            .font(.headline.monospacedDigit())
                                    } else {
                                        Text("Beyond model range")
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(.orange)
                                    }
                                    Text(row.integrationConfidence.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 105, ideal: 135)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("v2.planning.recommendations")
    }

    private func percent(_ factor: Double) -> String {
        (factor * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private func skyDetail(_ row: PlanningRecommendation) -> String {
        var parts: [String] = []
        if let visibleHours = row.visibleHours {
            parts.append("\(visibleHours.formatted(.number.precision(.fractionLength(1))))h visible")
        }
        if let culmination = row.culminationLocal {
            parts.append("culm. \(culmination)")
        }
        if let moonSeparation = row.moonSeparationDeg {
            parts.append("Moon \(moonSeparation.formatted(.number.precision(.fractionLength(0))))°")
        }
        return parts.isEmpty ? row.skyVerdict : parts.joined(separator: " · ")
    }

    private func displayName(_ row: PlanningRecommendation) -> String {
        if let name = row.target.commonNameHU { return "\(row.target.designation) · \(name)" }
        if let name = TargetCatalog.englishName(for: row.target) { return "\(row.target.designation) · \(name)" }
        return row.target.designation
    }
}
