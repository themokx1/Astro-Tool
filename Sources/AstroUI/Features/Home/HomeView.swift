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
        // Task 7b (2026-08-17): the 36% `ground` self-tint is gone, not
        // made opaque. This view is only ever rendered inside `V2RootView`'s
        // detail column, which now owns the page backdrop for all 21 routes
        // -- see the `.background(AstroTokens.Color.ground)` there.
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
            // Task 7 (2026-08-17, GroupBox removal): a heading plus spacing,
            // not a box on a box -- `GroupBox` painted macOS's default
            // opaque grey panel here, which is exactly the "strange grey
            // background" the owner reported.
            //
            // Task 7c: "no GroupBox" left this as bare text on the grey
            // backdrop, which is the opposite failure. It is a real content
            // block -- a heading, a recommendation, an action -- so it gets
            // the one raised surface, lighter than `ground` rather than
            // `GroupBox`'s grey-over-white.
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Continue where it matters").font(.headline)
                if let project = store.snapshot.nextProject {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.forward.circle.fill")
                            .font(.title2).foregroundStyle(AstroTokens.Color.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.displayName).font(.headline)
                            // Two distinct `Text("literal")` branches, not a
                            // ternary of two literals -- a ternary infers
                            // `String`, not `LocalizedStringKey` (same trap
                            // `planExportMenu`'s own comment below documents,
                            // and `PlanningView`'s Save/Saved fix works
                            // around a second way -- see
                            // `LocalizationCoverageTests.saveTargetLocalizesDespiteTernary`).
                            if project.phase == .collecting {
                                Text("Least collected active project · \(AstroFormat.duration(seconds: store.snapshot.nextProjectIntegrationSeconds)) so far.")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text("Open the project and plan its first capture series.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Open Project") {
                            openProject(project)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.home.open-project")
                    }
                } else if store.snapshot.hasActiveProjectsExcludedTonight {
                    // Task 1 (owner feedback wave 3): the owner's own words --
                    // a comet with a stale coordinate was recommended as
                    // "least collected active project" with an Open Project
                    // button, even though it can't meaningfully be continued.
                    // "Least collected" must never mean "least collected
                    // among things you cannot shoot" -- when nothing
                    // qualifies, say so instead of picking the worst
                    // candidate.
                    ContentUnavailableView {
                        Label("Nothing continuable tonight", systemImage: "moon.zzz")
                    } description: {
                        Text("Every active project's target is one the app already knows it cannot point at right now -- a comet with a stale coordinate, a missing coordinate, or an altitude too low tonight.")
                    }
                    .frame(minHeight: 140)
                } else {
                    Text("Create a project to start planning your next night.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .astroRaisedSurface()
            tonightRecommendations
        }
        .accessibilityIdentifier("v2.home.library-overview")
    }

    private var tonightRecommendations: some View {
        // Task 7 (2026-08-17, GroupBox removal): same heading-plus-spacing
        // fix as `libraryOverview` above -- the header row (title, info
        // button, export menu) is `ReviewWorkspace.frameReview`'s own
        // "HStack header, Divider, content" shape, not a `GroupBox` label.
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            HStack {
                Text("Best targets tonight").font(.headline)
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
            Divider()
            planExportMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Task 7c: same reasoning as `libraryOverview`'s "Continue where it
        // matters" block above -- a heading, a divider and a list of rows is
        // a content block, and a content block belongs on the raised layer.
        .astroRaisedSurface()
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
            // Task 1 (owner feedback wave 3): after filtering out targets the
            // shared `SkyVerdict` engine already knows can't be shot tonight
            // (comet stale coordinate, no coordinate, low altitude), this
            // library may legitimately have nothing left to recommend. An
            // empty, explained list is the honest outcome here -- not a list
            // padded with unusable rows, and not a silent blank box either.
            ContentUnavailableView {
                Label("Nothing to shoot tonight", systemImage: "sparkles.slash")
            } description: {
                // Two distinct `Text("literal")` branches, not a ternary of
                // two literals -- a ternary infers `String`, not
                // `LocalizedStringKey`, and would silently stop localizing
                // (see `LocalizationCoverageTests.saveTargetLocalizesDespiteTernary`).
                if store.snapshot.nightContext.isConfigured {
                    Text("Every target in this library is one the app already knows it cannot point at right now -- a comet with a stale coordinate, a missing coordinate, or an altitude too low tonight.")
                } else {
                    Text("Add a site or scan FITS coordinates to enable tonight planning.")
                }
            }
            .frame(minHeight: 160)
        } else {
            VStack(spacing: 0) {
                ForEach(store.snapshot.tonightRecommendations) { recommendation in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recommendation.displayName).font(.headline)
                            recommendationDetailText(recommendation)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // `HomeTonightRecommendation.verdict` is still
                        // `Planner.plan`'s own raw Hungarian sentence (V1/CLI's
                        // own consumer, unchanged) -- `SkyVerdict.parse(...)`
                        // gives the structured `SkyVerdictKind` `PlanningView`
                        // also renders from. W3-9: `.english` used to be
                        // rendered directly (a domain-layer `String`, so
                        // `Text(String)` always chose the verbatim overload,
                        // "good tonight" leaking straight through the
                        // Hungarian UI) -- `.displayLabel` maps the case to a
                        // `LocalizedStringKey` instead, at this view layer
                        // (see `PlanningStore.swift`'s `SkyVerdictKind`
                        // extension, next to `PlanningFit.displayLabel`).
                        Text(SkyVerdict.parse(recommendation.verdict).displayLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AstroTokens.Color.accent)
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

    /// W3-9: this used to be a single `Text(String)` built by joining an
    /// array of optionally-`nil` interpolated `String` fragments
    /// ("Visible …", "Culminates …", "…° max") with `" · "` -- exactly the
    /// store/view-composed-`String` leak this task's own doc names, and
    /// invisible to the extraction script twice over (the fragments are
    /// nested inside a `.map` closure, and the whole thing is joined before
    /// ever reaching `Text`). Building one `Text` per present fragment and
    /// concatenating them with `+` keeps each fragment a real `Text("…")`
    /// literal call site -- the same recipe `ArchiveVerdictHeader.reclaimText`
    /// already uses for its own two-clause sentence.
    @ViewBuilder
    private func recommendationDetailText(_ recommendation: HomeTonightRecommendation) -> some View {
        let parts: [Text] = [
            recommendation.visibleWindow.map { Text("Visible \($0)") },
            recommendation.culmination.map { Text("Culminates \($0)") },
            recommendation.maxAltitude.map { Text("\($0.formatted(.number.precision(.fractionLength(0))))° max") },
        ].compactMap { $0 }
        if let first = parts.first {
            parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
        } else {
            Text(verbatim: "")
        }
    }

    /// Backs the "Best targets tonight" header's ⓘ button.
    private static let tonightMetricInfo: [MetricInfoButton.Metric] = [
        .init(title: "Culmination", explanation: "When the target crosses the meridian at its highest altitude this night -- usually the best time to capture it.", glossaryTerm: "Culmination"),
        .init(title: "Max altitude", explanation: "The target's highest point above the horizon tonight. A higher altitude means a shorter, clearer path through the atmosphere.", glossaryTerm: "Airmass"),
        .init(title: "Verdict", explanation: "A short, honest summary of tonight's visibility for this target, combining its visible window and altitude."),
    ]

    private var header: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("OBSERVATORY WORKSPACE")
                .astroMicro()
                .foregroundStyle(AstroTokens.Color.accent)
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
                    Text("Site not set — add it in Settings ▸ Location")
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
                                        AstroTokens.Color.accent.opacity(0.45),
                                        AstroTokens.Color.accent.opacity(0.88),
                                        AstroTokens.Color.accent.opacity(0.45),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 2)
                        if let nowFraction = context.nowFraction {
                            Circle()
                                .fill(AstroTokens.Color.accent)
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
        // Task 7c: this was a hand-rolled card -- `.regularMaterial` plus its
        // own stroke, padding and radius -- i.e. a third convention next to
        // the table slot's flat `surface` fill and `MetricCard`'s glass. The
        // material was also the wrong layer for a rail that sits ON the page
        // rather than floating above it: it refracts the backdrop instead of
        // reading as content. One treatment now, same as every other block.
        .astroRaisedSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            context.isConfigured
                ? "Night context: \(context.leadingLabel), \(context.centerLabel), \(context.trailingLabel)."
                : "Night context: no site configured for this library yet."
        )
        .accessibilityIdentifier("v2.home.night-context")
    }
}
