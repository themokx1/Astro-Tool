import SwiftUI
import AstroApplication
import AstroCore
import UniformTypeIdentifiers

public struct HomeView: View {
    @Bindable private var store: HomeStore
    private let rootURL: URL?
    private let chooseLibrary: () -> Void
    private let openProject: (ProjectRecord) -> Void
    private let openProjectID: (UUID) -> Void
    @AppStorage("v2.general.showGuidance") private var showGuidance = true

    public init(
        store: HomeStore,
        rootURL: URL? = nil,
        chooseLibrary: @escaping () -> Void,
        openProject: @escaping (ProjectRecord) -> Void,
        openProjectID: @escaping (UUID) -> Void = { _ in }
    ) {
        _store = Bindable(store)
        self.rootURL = rootURL
        self.chooseLibrary = chooseLibrary
        self.openProject = openProject
        self.openProjectID = openProjectID
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
                header
                NightContextRail(context: store.snapshot.nightContext)
                if store.snapshot.libraryName == nil {
                    emptyLibrary
                } else {
                    libraryOverview
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(AstroTokens.Spacing.spacious)
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
        .navigationTitle("Home")
        .accessibilityLabel("Home")
        .accessibilityIdentifier("v2.detail.home")
    }

    private var libraryOverview: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(title: "Projects", value: "\(store.snapshot.projectCount)", detail: "In \(store.snapshot.libraryName ?? "library")", systemImage: "scope")
                MetricCard(title: "Nights", value: "\(store.snapshot.nightCount)", detail: "Indexed observing sessions", systemImage: "moon.stars")
            }
            GroupBox("Continue where it matters") {
                if let project = store.snapshot.nextProject {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.forward.circle.fill")
                            .font(.title2).foregroundStyle(AstroTokens.Color.spectralBlue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.displayName).font(.headline)
                            Text(project.phase == .collecting
                                ? "Least collected active project · \(duration(store.snapshot.nextProjectIntegrationSeconds)) so far."
                                : "Open the project and plan its first capture series.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Project") {
                            openProject(project)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.home.open-project")
                    }
                    .padding(8)
                } else {
                    Text("Create a project to start planning your next night.")
                        .foregroundStyle(.secondary).padding(8)
                }
            }
            tonightRecommendations
        }
        .accessibilityIdentifier("v2.home.library-overview")
    }

    private var tonightRecommendations: some View {
        GroupBox {
            planExportMenu
        } label: {
            HStack {
                Text("Best targets tonight")
                MetricInfoButton(metrics: Self.tonightMetricInfo)
                Spacer()
                ExportMenu(
                    title: "Export Plan",
                    systemImage: "square.and.arrow.up",
                    items: planExportItems,
                    accessibilityID: "v2.home.plan-export"
                )
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .accessibilityIdentifier("v2.home.tonight-recommendations")
    }

    private var planExportItems: [ExportMenuItem] {
        guard let rootURL else { return [] }
        let plans = store.tonightPlans
        let shoppingItems = store.calibShoppingItems
        return [
            .file(title: "Plan CSV…", systemImage: "tablecells", contentType: .commaSeparatedText) {
                let export = try ExportService.production(rootURL: rootURL).planCSV(plans: plans)
                return (export.content, export.suggestedFilename, [])
            },
            .clipboard(title: "Copy Plan", systemImage: "doc.on.clipboard") {
                try ExportService.production(rootURL: rootURL).planClipboardText(plans: plans)
            },
            .clipboard(title: "Copy Calibration Shopping List", systemImage: "list.bullet.clipboard") {
                try ExportService.production(rootURL: rootURL).calibShoppingListMarkdown(items: shoppingItems)
            },
        ]
    }

    @ViewBuilder private var planExportMenu: some View {
        if store.snapshot.tonightRecommendations.isEmpty {
            Text("No astronomical recommendation is available yet. Add a site or scan FITS coordinates to enable tonight planning.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } else {
            VStack(spacing: 0) {
                ForEach(store.snapshot.tonightRecommendations) { recommendation in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recommendation.displayName).font(.headline)
                            Text([
                                recommendation.visibleWindow.map { "Visible \($0)" },
                                recommendation.culmination.map { "Culminates \($0)" },
                                recommendation.maxAltitude.map { "\($0.formatted(.number.precision(.fractionLength(0))))° max" }
                            ].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // `HomeTonightRecommendation.verdict` is still
                        // `Planner.plan`'s own raw Hungarian sentence (V1/CLI's
                        // own consumer, unchanged) -- `SkyVerdict.parse(...)
                        // .english` is the same structured-parse translation
                        // `PlanningView` uses, so this English UI never shows
                        // it directly (V2 UI/UX audit, 2026-08-15, section 4).
                        Text(SkyVerdict.parse(recommendation.verdict).english)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AstroTokens.Color.spectralBlue)
                        if let projectID = recommendation.projectID {
                            Button("Open") { openProjectID(projectID) }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("v2.home.open-recommendation.\(recommendation.id)")
                        }
                    }
                    .padding(.vertical, 9)
                    if recommendation.id != store.snapshot.tonightRecommendations.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// Backs the "Best targets tonight" header's ⓘ button.
    private static let tonightMetricInfo: [MetricInfoButton.Metric] = [
        .init(title: "Culmination", explanation: "When the target crosses the meridian at its highest altitude this night -- usually the best time to capture it.", glossaryTerm: "Culmination"),
        .init(title: "Max altitude", explanation: "The target's highest point above the horizon tonight. A higher altitude means a shorter, clearer path through the atmosphere.", glossaryTerm: "Airmass"),
        .init(title: "Verdict", explanation: "A short, honest summary of tonight's visibility for this target, combining its visible window and altitude."),
    ]

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("OBSERVATORY WORKSPACE")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(AstroTokens.Color.spectralBlue)
            Text("Prepare the next clear night")
                .font(.largeTitle.weight(.semibold))
            if showGuidance {
                Text("Keep plans, observing nights, and library health in one quiet workspace.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("v2.home.guidance-caption")
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No library open", systemImage: "sparkles.rectangle.stack")
        } description: {
            Text("Choose an image folder, then explore the Library workspace through a local, read-only index.")
        } actions: {
            Button("Choose Image Library…", action: chooseLibrary)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose Image Library")
        }
        .frame(maxWidth: .infinity, minHeight: 250)
    }
}

/// V2 UI/UX audit (2026-08-14) section 4: this used to draw a dusk/
/// observation-window/dawn timeline from hardcoded, fixed fractions of the
/// available width, with permanently fixed labels -- nothing ever supplied
/// it real data, so it read as a genuine plot while always showing the same
/// thing regardless of which library was open or what time it was. It now
/// renders `context`'s own `isConfigured` flag honestly: a real dusk-to-dawn
/// bar with a real "now" marker when a site resolved, or a plain
/// unconfigured state -- never a decorative fake plot.
private struct NightContextRail: View {
    let context: HomeSnapshot.NightContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Night context", systemImage: "moon.stars")
                    .font(.headline)
                Spacer()
                if !context.isConfigured {
                    Text("Site not set")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if context.isConfigured {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        AstroTokens.Color.spectralBlue.opacity(0.45),
                                        AstroTokens.Color.spectralViolet.opacity(0.88),
                                        AstroTokens.Color.spectralBlue.opacity(0.45),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 2)
                        if let nowFraction = context.nowFraction {
                            Circle()
                                .fill(AstroTokens.Color.spectralViolet)
                                .frame(width: 7, height: 7)
                                .offset(x: proxy.size.width * nowFraction - 3.5)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 12)

                HStack {
                    Text(context.leadingLabel)
                    Spacer()
                    Text(context.centerLabel)
                    Spacer()
                    Text(context.trailingLabel)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("No observing site is resolved for this library yet, so tonight's dusk-to-dawn window can't be shown here. AstroTool derives it automatically from your FITS files' own site coordinates once they're indexed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AstroTokens.Spacing.standard)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
                .stroke(AstroTokens.Color.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            context.isConfigured
                ? "Night context: \(context.leadingLabel), \(context.centerLabel), \(context.trailingLabel)."
                : "Night context: no site configured for this library yet."
        )
        .accessibilityIdentifier("v2.home.night-context")
    }
}
