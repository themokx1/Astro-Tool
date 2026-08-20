import AstroApplication
import SwiftUI

public struct SeriesInspector: View {
    public let snapshot: ReviewSeriesSnapshot
    /// W3-12 finding 3: used to be fire-and-forget (`(EquipmentFilter) ->
    /// Void`), so this view had no way to know whether the assignment it
    /// just requested actually landed. `async throws` lets both call sites
    /// below await the real outcome and only report success (clearing the
    /// "Add a new filter" fields) once the write has genuinely settled.
    public let assignFilter: (EquipmentFilter) async throws -> Void
    @State private var settings = SettingsStore()
    @State private var manufacturer = ""
    @State private var model = ""
    @State private var newFilterPassband = EquipmentFilterPassband.unknown
    @State private var filterError: String?

    public init(snapshot: ReviewSeriesSnapshot, assignFilter: @escaping (EquipmentFilter) async throws -> Void = { _ in }) {
        self.snapshot = snapshot
        self.assignFilter = assignFilter
    }

    public var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Exposure", value: exposure)
                LabeledContent("Sensor", value: snapshot.series.sensorMode.localizedText)
                LabeledContent("Passband", value: passband)
                // V2 localization sweep (W3-13): `LabeledContent(_:value:)`
                // always renders its `value` as plain verbatim text, by
                // design (it is meant for data, not UI copy) -- so
                // `filterName ?? "No filter recorded"` never localized even
                // though the phrase already had an `hu.lproj` entry. The
                // content-closure initializer lets the real filter name
                // (data) stay verbatim while the fallback goes through
                // `Text`'s own `LocalizedStringKey` initializer.
                LabeledContent("Filter") {
                    if let filterName = snapshot.series.filterName {
                        Text(filterName)
                    } else {
                        Text("No filter recorded")
                    }
                }
                Menu("Choose Filter…") {
                    if settings.filters.isEmpty { Text("No saved filters") }
                    ForEach(settings.filters) { filter in
                        Button(filterTitle(filter)) { assign(filter) }
                    }
                }
                // W3-12 finding 3: moved out of the `DisclosureGroup` below
                // so a failure from EITHER path above (an existing filter
                // from the menu, or a brand-new one from "Save and Use")
                // is visible regardless of whether that group happens to be
                // expanded -- a collapsed group used to hide the only place
                // this error ever rendered.
                if let filterError { Text(filterError).foregroundStyle(.red) }
                DisclosureGroup("Add a new filter") {
                    TextField("Manufacturer", text: $manufacturer)
                    TextField("Model", text: $model)
                    Picker("Passband", selection: $newFilterPassband) {
                        ForEach(EquipmentFilterPassband.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    Button("Save and Use") {
                        do {
                            let filter = try settings.createFilter(manufacturer: manufacturer, model: model, passband: newFilterPassband)
                            assign(filter) { manufacturer = ""; model = ""; newFilterPassband = .unknown }
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
        // Task 6 (2026-08-17, Liquid Glass): same panel-gets-glass treatment
        // as `InspectorView`'s own Form-based panels -- a `Form` of
        // `LabeledContent`/`Menu`/`TextField` rows, never a `Table`/`List`.
        // Used both as the sidebar inspector's own series panel and
        // `ReviewWorkspace`'s embedded one; in both call sites it sits in
        // its own pane/branch, never as an ancestor of that screen's own
        // `List`/`Table` (`ReviewWorkspace.seriesList`/`frameReview` are
        // separate `HSplitView` panes, not descendants of this view).
        .glassEffect(.regular, in: ConcentricRectangle())
        .accessibilityIdentifier("v2.review.inspector")
    }

    private var exposure: String {
        AstroFormat.exposureSeconds(snapshot.series.exposureSeconds)
    }

    // W6-D fix: this used to derive a display string from the raw case name
    // (`rawValue.replacingOccurrences(of: "_", with: " ").capitalized`) --
    // exactly the pre-fix shape `NightsStore.swift`'s own `SeriesPassband
    // .displayLabel`/`.localizedText` doc comment describes ("dual_band" ->
    // "Dual band", never translated). `.localizedText` already exists on
    // this same `SeriesPassband` type for the identical `LabeledContent
    // (_:value:)` call shape (`InspectorView.swift`'s `SeriesSummaryPanel`)
    // -- it just never got propagated here.
    private var passband: String {
        snapshot.series.passband.localizedText
    }

    private func filterTitle(_ filter: EquipmentFilter) -> String {
        [filter.manufacturer, filter.model].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Awaits `assignFilter`'s real outcome before doing anything else --
    /// `onSuccess` (the "Add a new filter" form's own field-clearing) only
    /// runs once the write has actually landed, and any failure surfaces
    /// through `filterError` instead of being dropped on the floor. W3-12
    /// finding 3: this replaces the old fire-and-forget `assignFilter(filter)`
    /// call that cleared the form immediately regardless of whether the
    /// write behind it ever succeeded.
    private func assign(_ filter: EquipmentFilter, onSuccess: @escaping () -> Void = {}) {
        Task {
            do {
                try await assignFilter(filter)
                filterError = nil
                onSuccess()
            } catch {
                filterError = error.localizedDescription
            }
        }
    }
}
