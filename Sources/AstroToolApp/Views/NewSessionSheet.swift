import AstroCore
import SwiftUI

struct NewSessionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var catalog: String
    @State private var name: String
    @State private var catalogQuery: String
    @State private var selectedCatalogTarget: CatalogTarget?
    @State private var usesCustomTarget = false
    @State private var dateText: String = NewSessionSheet.today()
    @State private var createsInitialCapture = true
    @State private var captureName = "OSC · szűrő nélkül"
    @State private var captureSensor: SensorMode = .osc
    @State private var captureSignal: SignalMode = .unfiltered
    @State private var captureManufacturer = ""
    @State private var captureModel = ""

    /// `prefillDesignation` (R10-B4): "Felfedezés"'s row-scoped "Új session
    /// létrehozása…" action opens this sheet already primed with the
    /// catalog target's OWN designation split apart (`splitDesignation`
    /// below) -- re-typing e.g. "NGC" + "7000" by hand for a target the
    /// catalog already fully identifies would be needless friction. `nil`
    /// (the default) keeps every other call site (the toolbar "+", ⌘N, the
    /// "Új session…" empty-state buttons) behaving exactly as before --
    /// blank fields.
    init(prefillDesignation: String? = nil) {
        let catalogTarget = prefillDesignation.flatMap { designation in
            TargetCatalog.all.first { $0.designation == designation }
        }
        if let prefillDesignation, let split = Self.splitDesignation(prefillDesignation) {
            _catalog = State(initialValue: split.catalog)
            _name = State(initialValue: split.name)
            _catalogQuery = State(initialValue: prefillDesignation)
            _selectedCatalogTarget = State(initialValue: catalogTarget)
        } else {
            _catalog = State(initialValue: "")
            _name = State(initialValue: "")
            _catalogQuery = State(initialValue: "")
            _selectedCatalogTarget = State(initialValue: nil)
        }
    }

    /// Splits a `CatalogTarget.designation` into `(catalog, name)` the way
    /// `Sanitizer.makeTarget(catalog:name:)` expects to reassemble it --
    /// `"M 42"` -> `("M", "42")`, `"NGC 7000"` -> `("NGC", "7000")`,
    /// `"Sh2-101"` -> `("Sh2", "101")`. The dash check MUST come first: a
    /// digit-split alone would mis-split `"Sh2-101"` at the "2" already
    /// inside "Sh2" (-> `("Sh", "2-101")`), since "Sh2" itself ends in a
    /// digit -- the SAME reason `TargetCatalog`'s own doc comment gives for
    /// why Sh2 designations use a dash at all. Deliberately keeps
    /// `commonNameHU` OUT of `name` -- the numeric/dash part alone is
    /// simpler and more predictable than guessing whether a user wants the
    /// Hungarian common name prepended, appended, or not used at all; they
    /// can always type their own. `nil` for anything that doesn't match one
    /// of `TargetCatalog`'s three designation shapes at all (defensive
    /// only -- every caller today only ever passes a real
    /// `CatalogTarget.designation`).
    static func splitDesignation(_ designation: String) -> (catalog: String, name: String)? {
        if let dashIndex = designation.firstIndex(of: "-") {
            let catalog = String(designation[designation.startIndex..<dashIndex])
            let name = String(designation[designation.index(after: dashIndex)...])
            guard !catalog.isEmpty, !name.isEmpty else { return nil }
            return (catalog, name)
        }
        guard let digitIndex = designation.firstIndex(where: \.isNumber) else { return nil }
        let catalog = String(designation[designation.startIndex..<digitIndex]).trimmingCharacters(in: .whitespaces)
        let name = String(designation[digitIndex...]).trimmingCharacters(in: .whitespaces)
        guard !catalog.isEmpty, !name.isEmpty else { return nil }
        return (catalog, name)
    }

    private var previewTarget: String {
        if let selectedCatalogTarget {
            return SessionCreator.targetFolder(
                for: selectedCatalogTarget,
                root: URL(fileURLWithPath: appState.config.rootPath, isDirectory: true),
                indexedFolders: appState.stats.map(\.target)
            )
        }
        return Sanitizer.makeTarget(catalog: catalog, name: name)
    }

    private var catalogMatches: [CatalogTarget] {
        TargetCatalog.search(catalogQuery, limit: 8)
    }

    private var selectedTargetHours: Double? {
        guard let selectedCatalogTarget else { return nil }
        return IntegrationGoalCalculator.recommendedHours(
            rule: appState.config.integrationReference,
            setup: ImagingSetupProfile.defaultSetup(in: appState.config.imagingSetups),
            target: selectedCatalogTarget
        )
    }

    private var dateIsValid: Bool {
        guard let parsed = SessionDateParser.parse(dateText) else { return false }
        return parsed.isCanonical
    }

    private var initialCapture: CaptureGroupDraft? {
        guard createsInitialCapture else { return nil }
        return CaptureGroupDraft(
            slug: CaptureGroupDraft.suggestedSlug(for: captureName),
            displayName: captureName,
            sensorMode: captureSensor,
            signalMode: captureSignal,
            filterManufacturer: captureManufacturer,
            filterModel: captureModel
        )
    }

    private var matchingTargets: [String] {
        guard !previewTarget.isEmpty else { return [] }
        return appState.stats
            .map(\.target)
            .filter { $0.localizedCaseInsensitiveContains(previewTarget) }
            .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Új session létrehozása").font(.headline)

            Picker("Célpont mód", selection: $usesCustomTarget) {
                Text("Katalógusból").tag(false)
                Text("Egyedi célpont").tag(true)
            }
            .pickerStyle(.segmented)

            if usesCustomTarget {
                TextField("Katalógusszám (opcionális, pl. C 14)", text: $catalog)
                TextField("Célpont neve", text: $name)
                Text("Az egyedi név nincs a katalógushoz kötve. Ellenőrizd a mappanév-előnézetet, hogy ne jöjjön létre elírt duplikátum.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                TextField("Keresés: IC 1396, Elephant Trunk vagy Elefántormány", text: $catalogQuery)
                    .textFieldStyle(.roundedBorder)

                if selectedCatalogTarget == nil, !catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if catalogMatches.isEmpty {
                            Text("Nincs találat. Próbálj katalógusszámot, angol vagy magyar nevet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(catalogMatches, id: \.designation) { target in
                                Button {
                                    selectedCatalogTarget = target
                                    catalogQuery = [target.designation, TargetCatalog.englishName(for: target)]
                                        .compactMap { $0 }
                                        .joined(separator: " · ")
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(target.designation).fontWeight(.semibold)
                                            Text([
                                                TargetCatalog.englishName(for: target), target.commonNameHU,
                                            ].compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(targetKindLabel(target.kind))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }

                if let target = selectedCatalogTarget {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.designation + " · " + (TargetCatalog.englishName(for: target) ?? target.commonNameHU ?? "katalóguscélpont"))
                                .fontWeight(.semibold)
                            Text([
                                target.commonNameHU,
                                target.sizeArcmin.map { String(format: "méret %.1f′", $0) },
                                target.magnitude.map { String(format: "magnitúdó %.1f", $0) },
                                TargetCatalog.estimatedSurfaceBrightness(for: target).map {
                                    String(format: "becsült felületi fényesség %.1f mag/arcsec²", $0)
                                },
                                selectedTargetHours.map { String(format: "automatikus cél %.1f óra", $0) },
                            ].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Másik") {
                            selectedCatalogTarget = nil
                            catalogQuery = ""
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))
                }
            }

            Text("Létrejövő célpontmappa: \(previewTarget.isEmpty ? TDFormat.missingCell : previewTarget)")
                .foregroundStyle(.secondary)

            TextField("Dátum (YYYY-MM-DD)", text: $dateText)
            if !dateIsValid {
                Text("Érvénytelen dátum — YYYY-MM-DD formátum szükséges.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Első capture-gyűjtés létrehozása", isOn: $createsInitialCapture)
                        .font(.subheadline.weight(.semibold))
                    if createsInitialCapture {
                        HStack {
                            Button("OSC · szűrő nélkül") {
                                captureName = "OSC · szűrő nélkül"
                                captureSensor = .osc
                                captureSignal = .unfiltered
                                captureManufacturer = ""
                                captureModel = ""
                            }
                            Button("OSC · dual-band") {
                                captureName = "OSC · dual-band"
                                captureSensor = .osc
                                captureSignal = .dualBand
                                captureManufacturer = ""
                                captureModel = ""
                            }
                        }
                        TextField("Gyűjtés neve", text: $captureName)
                        HStack {
                            Picker("Szenzor", selection: $captureSensor) {
                                ForEach(SensorMode.allCases, id: \.self) { Text($0.displayNameHU).tag($0) }
                            }
                            Picker("Fénysáv", selection: $captureSignal) {
                                ForEach(SignalMode.allCases, id: \.self) { Text($0.displayNameHU).tag($0) }
                            }
                        }
                        if captureSignal == .dualBand || captureSignal == .narrowband {
                            HStack {
                                TextField("Szűrő gyártó", text: $captureManufacturer)
                                TextField("Modell", text: $captureModel)
                            }
                        }
                        Text("A sessionön belül külön lights/flats/darks/biases ág, valamint külön stack és process hely készül.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if usesCustomTarget, !matchingTargets.isEmpty {
                Text("Meglévő hasonló célpontok:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(matchingTargets.prefix(5), id: \.self) { existing in
                    Button(existing) {
                        catalog = ""
                        name = existing
                    }
                    .buttonStyle(.link)
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Mégse") { dismiss() }
                Button("Létrehozás") {
                    appState.createSession(
                        catalog: catalog,
                        name: name,
                        date: dateText,
                        initialCapture: initialCapture,
                        catalogTarget: usesCustomTarget ? nil : selectedCatalogTarget
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    (usesCustomTarget ? name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : selectedCatalogTarget == nil)
                        || !dateIsValid || appState.isBusy
                        || (createsInitialCapture && captureName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }
        }
        .padding(20)
        .frame(minWidth: 540)
        .onAppear {
            // Existing-target autocomplete reads `appState.stats`; make sure
            // it's populated even if the user never visited the Stats tab.
            if appState.stats.isEmpty { appState.loadStats() }
        }
        .onChange(of: appState.lastCreatedSessionDir) { _, newValue in
            if newValue != nil { dismiss() }
        }
    }

    private func targetKindLabel(_ kind: CatalogTargetKind) -> String {
        switch kind {
        case .galaxy: "galaxis"
        case .emissionNebula: "emissziós köd"
        case .planetaryNebula: "planetáris köd"
        case .supernovaRemnant: "szupernóva-maradvány"
        case .openCluster: "nyílthalmaz"
        case .globularCluster: "gömbhalmaz"
        case .reflectionNebula: "reflexiós köd"
        case .darkNebula: "sötét köd"
        case .other: "egyéb"
        }
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
