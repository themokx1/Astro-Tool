import AstroApplication
import AstroCore
import SwiftUI

/// English display text for `CaptureRuleSuggestion.Basis` -- the "why" line
/// under a proposed rule, so the user can judge how much to trust it before
/// approving (a folder-name guess is weaker evidence than "every other
/// night with this exact folder name already says so").
private extension CaptureRuleSuggestion.Basis {
    var displayLabel: LocalizedStringKey {
        switch self {
        case .slugNameText: "Inferred from this folder's own name"
        case .sameSlugOtherNight: "Matches every other night using this same folder name"
        case .defaultImagingSetup: "Matches this library's default imaging setup"
        }
    }
}

/// V3 5.4 "Metadata fixer": the batched "missing filters" workspace the
/// spec asks for (`MetadataFixerView`), grouping every light frame whose
/// `CaptureResolver`-resolved filter is still empty by target/date/folder --
/// almost always a Canon CR3 night, since CR3 carries no FITS header at all.
/// Each gap shows a deterministic rule suggestion (`CaptureRuleSuggestionEngine`)
/// the user must explicitly approve, a manual override form for anything the
/// engine can't guess, and a one-click "doesn't inherit the group's filter"
/// action for the duoband-inheritance-override case the spec calls out by
/// name. All writes go through `CaptureAssignmentCommand`, gated on
/// `accessMode` exactly like every other V2 mutation.
public struct MetadataFixerView: View {
    let rootURL: URL?
    let accessMode: LibraryAccessMode
    let onLibraryFindingsChanged: (() -> Void)?
    @State private var store = MetadataFixerStore()
    @State private var manualSignalMode: SeriesPassband?
    @State private var manualFilterManufacturer = ""
    @State private var manualFilterModel = ""
    @State private var manualFilterName = ""

    public init(
        rootURL: URL?,
        accessMode: LibraryAccessMode = .readOnly,
        onLibraryFindingsChanged: (() -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.onLibraryFindingsChanged = onLibraryFindingsChanged
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.isLoading {
                ProgressView("Reading capture metadata…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = store.errorMessage {
                ContentUnavailableView {
                    Label("Capture metadata unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    RetryButton(identifier: "v2.metadata-fixer.try-again") {
                        Task { await load() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.gaps.isEmpty && store.conflicts.isEmpty {
                ContentUnavailableView {
                    Label("Every frame has a resolved filter", systemImage: "checkmark.circle")
                } description: {
                    Text("No session in this library has a light frame with a missing filter or a metadata conflict.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    gapList
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
                    Divider()
                    if let gap = store.selectedGap {
                        detailPane(for: gap)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ContentUnavailableView(
                            "Select a session",
                            systemImage: "camera.metering.matrix",
                            description: Text("Choose a folder on the left to review its missing filter and any suggested fix.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .astroRaisedSurface(.flush)
        .padding(AstroTokens.Spacing.spacious)
        .task { await load() }
        .accessibilityIdentifier("v2.metadata-fixer")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.metering.matrix").font(.title2).foregroundStyle(AstroTokens.Color.accent)
            VStack(alignment: .leading) {
                Text("Metadata Fixer").font(.title2.bold())
                Text("Fills in the FILTER field folder/date/rig at a time, with manual overrides that survive every rescan.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(20)
    }

    private var gapList: some View {
        List(selection: Binding(
            get: { store.selectedGapID },
            set: { newValue in
                guard let newValue, let gap = store.gaps.first(where: { $0.id == newValue }) else { return }
                Task { await store.selectGap(gap) }
            }
        )) {
            if !store.conflicts.isEmpty {
                Section("Conflicts") {
                    ForEach(Array(store.conflicts.enumerated()), id: \.offset) { _, conflict in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conflict.path).font(.caption.monospaced()).lineLimit(1)
                            Text(conflict.message).font(.caption2).foregroundStyle(AstroTokens.Color.attention)
                        }
                    }
                }
                .accessibilityIdentifier("v2.metadata-fixer.conflicts")
            }
            Section("Missing filters") {
                ForEach(store.gaps) { gap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gap.label).font(.body)
                        Text("\(gap.paths.count) frames · \(gap.date)").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(gap.id)
                }
            }
            .accessibilityIdentifier("v2.metadata-fixer.gaps")
        }
    }

    @ViewBuilder
    private func detailPane(for gap: CaptureFilterGap) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(gap.label).font(.title3.bold())
                    LabeledContent("Session", value: "\(gap.target) · \(gap.date)")
                    LabeledContent("Frames", value: "\(gap.paths.count)")
                    if let instrument = gap.instrument {
                        LabeledContent("Rig", value: instrument)
                    }
                }

                if gap.groupID == nil {
                    Label(
                        "These frames aren't assigned to a capture group yet -- assign them to one first (Library ▸ Classify) before a rule can be applied here.",
                        systemImage: "questionmark.folder"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                } else {
                    suggestionCard
                    manualOverrideForm(for: gap)
                }

                if let applyErrorMessage = store.applyErrorMessage {
                    Label(applyErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(AstroTokens.Color.critical)
                }
                if store.lastReceipt != nil {
                    Label("Saved -- this override survives every future rescan.", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(AstroTokens.Color.ok)
                }

                Button("Clear override for this session's frames") {
                    Task { await store.clearOverride() }
                }
                .disabled(accessMode != .mutationEnabled)
                .accessibilityIdentifier("v2.metadata-fixer.clear")
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var suggestionCard: some View {
        if store.isSuggesting {
            ProgressView("Looking for a rule…")
        } else if let suggestion = store.suggestion {
            sectionCard("Suggested rule") {
                VStack(alignment: .leading, spacing: 8) {
                    if let signalMode = suggestion.signalMode,
                       let passband = SeriesPassband(rawValue: signalMode.rawValue)
                    {
                        LabeledContent("Signal mode", value: passband.localizedText)
                    }
                    if let filterName = CaptureFilterLabel.make(
                        manufacturer: suggestion.filterManufacturer,
                        model: suggestion.filterModel,
                        name: suggestion.filterName
                    ) {
                        LabeledContent("Filter", value: filterName)
                    }
                    Label(suggestion.basis.displayLabel, systemImage: "lightbulb")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Apply this rule to \(store.selectedGap?.paths.count ?? 0) frames") {
                        Task { await store.applySuggestion() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(accessMode != .mutationEnabled)
                    .accessibilityIdentifier("v2.metadata-fixer.apply-suggestion")
                }
            }
        } else {
            Label(
                "Not enough context for an automatic suggestion -- enter the filter by hand below.",
                systemImage: "questionmark.circle"
            )
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func manualOverrideForm(for gap: CaptureFilterGap) -> some View {
        sectionCard("Manual override") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Signal mode", selection: $manualSignalMode) {
                    Text("Not set").tag(SeriesPassband?.none)
                    ForEach(SeriesPassband.allCases.filter { $0 != .unknown }, id: \.self) { passband in
                        Text(passband.displayLabel).tag(SeriesPassband?.some(passband))
                    }
                }
                TextField("Manufacturer", text: $manualFilterManufacturer)
                TextField("Model", text: $manualFilterModel)
                TextField("Filter name", text: $manualFilterName)
                HStack {
                    Button("Save override") {
                        Task {
                            await store.applyManualOverride(
                                signalMode: manualSignalMode.flatMap { SignalMode(rawValue: $0.rawValue) },
                                filterManufacturer: manualFilterManufacturer,
                                filterModel: manualFilterModel,
                                filterName: manualFilterName
                            )
                        }
                    }
                    .disabled(accessMode != .mutationEnabled)
                    .accessibilityIdentifier("v2.metadata-fixer.save-manual")

                    // The duoband-inheritance-override case named in the spec:
                    // one click to say "this folder/rig does NOT inherit the
                    // group's own duoband (or any other) filter" without
                    // filling in a competing filter of its own.
                    Button("Doesn't inherit the group's filter") {
                        Task { await store.markDoesNotInheritGroupFilter() }
                    }
                    .disabled(accessMode != .mutationEnabled)
                    .accessibilityIdentifier("v2.metadata-fixer.does-not-inherit")
                }
                if accessMode != .mutationEnabled {
                    Text("Requires write access. Enable write operations in Settings to save an override.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A heading-plus-divider grouping, per this codebase's own
    /// `noGroupBoxInFeatureViews` design gate: `GroupBox` "paints an opaque
    /// box over the design" and is banned from `Features/`; the accepted
    /// shape (`ReviewWorkspace.frameReview`'s own convention) is a bold
    /// caption header, a `Divider`, then the content -- no border, no
    /// second surface.
    private func sectionCard(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Divider()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        guard let rootURL else { return }
        await store.load(rootURL: rootURL, accessMode: accessMode)
        store.onLibraryFindingsChanged = onLibraryFindingsChanged
    }
}
