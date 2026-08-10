import AstroCore
import SwiftUI

/// Versioned, fully skippable first-run setup. Every page edits local draft
/// state; only the final review writes config/filter inventory.
struct OnboardingWizardView: View {
    @Environment(AppState.self) private var appState

    let onSkipAll: () -> Void
    let onFinished: () -> Void

    private enum Step: Int, CaseIterable, Hashable {
        case welcome, location, equipment, filters, quality, integration, review

        var title: String {
            switch self {
            case .welcome: "Üdvözlés"
            case .location: "Helyszín"
            case .equipment: "Felszerelések"
            case .filters: "Szűrők"
            case .quality: "Minőség"
            case .integration: "Célidő"
            case .review: "Ellenőrzés"
            }
        }

        var symbol: String {
            switch self {
            case .welcome: "sparkles"
            case .location: "location"
            case .equipment: "camera.aperture"
            case .filters: "camera.filters"
            case .quality: "waveform.path.ecg"
            case .integration: "clock"
            case .review: "checklist"
            }
        }
    }

    private struct FilterDraft: Identifiable {
        let id = UUID()
        var databaseID: Int64?
        var manufacturer: String
        var model: String
        var name: String
        var signalMode: SignalMode
        var notes: String
        var createdAt: Double
    }

    @State private var step: Step = .welcome
    @State private var skipped: Set<Step> = []
    @State private var loaded = false
    @State private var baseConfig = AstroConfig()
    @State private var errorText: String?

    @State private var manualSite = false
    @State private var siteName = "Alapértelmezett"
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var weatherEnabled = false

    @State private var setups: [ImagingSetupProfile] = []
    @State private var filterDrafts: [FilterDraft] = []
    @State private var filterInventoryReady = false

    @State private var ratingWorkers = 4
    @State private var outlierZScore = 2.0
    @State private var sirilPath = "/Applications/Siril.app/Contents/MacOS/siril-cli"
    @State private var integrationRule = IntegrationReferenceRule()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if loaded { page } else { ProgressView("Beállítások betöltése…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 860, height: 680)
        .task {
            if !loaded { await loadDraft() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Részletes személyre szabás", systemImage: "slider.horizontal.3")
                    .font(.title2.bold())
                Spacer()
                Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.self) { item in
                    VStack(spacing: 4) {
                        Image(systemName: skipped.contains(item) ? "forward.fill" : item.symbol)
                        Text(item.title).lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(item == step ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity)
                    Rectangle()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 2)
                }
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: welcomePage
        case .location: locationPage
        case .equipment: equipmentPage
        case .filters: filtersPage
        case .quality: qualityPage
        case .integration: integrationPage
        case .review: reviewPage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Rendezzük be a valódi asztrofotós munkafolyamatodhoz", systemImage: "sparkles")
                .font(.title.bold())
            Text("Több rövid oldalon megadhatod a helyszínt, több kamera–optika setupot, saját szűrőket, minőségi küszöböket és az automatikus integrációs referencia alapját.")
                .font(.title3)
            GroupBox("Biztonság") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("A könyvtár beolvasása alapból csak olvas.", systemImage: "eye")
                    Label("Fájlt csak külön előnézett és megerősített művelet hoz létre vagy mozgat.", systemImage: "checkmark.shield")
                    Label("Nincs automatikus törlés vagy automatikus archíválás.", systemImage: "trash.slash")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            Text("Minden oldal külön kihagyható. A teljes varázsló is bezárható, és később a Beállításokból újraindítható.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(26)
    }

    private var locationPage: some View {
        Form {
            Section("Koordináták") {
                Toggle("Kézi megfigyelési helyszín", isOn: $manualSite)
                if manualSite {
                    TextField("Helyszín neve", text: $siteName)
                    HStack {
                        TextField("Szélesség (°)", text: $latitude)
                        TextField("Hosszúság (°)", text: $longitude)
                    }
                } else {
                    Text("Automatikus felismerés a FITS SITELAT/SITELONG mezőiből.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Időjárás") {
                Toggle("Open-Meteo felhőzet-előrejelzés", isOn: $weatherEnabled)
                Text("Bekapcsolva a koordináta két tizedesre kerekítve elhagyja a gépet. Alapból ki van kapcsolva.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var equipmentPage: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Kamera–optika setupok").font(.headline)
                    Text("Többet is felvehetsz; a csillag jelöli az automatikus tervezés alapsetupját.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                setupMenu
            }
            .padding()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($setups) { $setup in setupCard($setup) }
                }
                .padding([.horizontal, .bottom])
            }
        }
    }

    private var setupMenu: some View {
        Menu {
            Button("APS-C alapsetup") { addSetup(Self.apsCBaseTemplate()) }
            Button("Full frame alapsetup") { addSetup(Self.fullFrameBaseTemplate()) }
            Divider()
            Button("Egyedi setup") {
                addSetup(ImagingSetupProfile(
                    id: UUID().uuidString, name: "Új setup", cameraName: "Kamera",
                    cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.6,
                    focalLengthMinMM: 200, focalLengthMaxMM: 200, defaultFocalLengthMM: 200,
                    fNumber: 5, relativeEfficiency: 1
                ))
            }
        } label: { Label("Setup hozzáadása", systemImage: "plus") }
    }

    private func setupCard(_ setup: Binding<ImagingSetupProfile>) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    TextField("Setup neve", text: setup.name).font(.headline)
                    Button {
                        setDefaultSetup(setup.wrappedValue.id)
                    } label: {
                        Image(systemName: setup.wrappedValue.isDefault ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(setup.wrappedValue.isDefault ? .yellow : .secondary)
                    Button(role: .destructive) { removeSetup(setup.wrappedValue.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    LabeledContent("Kamera") { TextField("Név", text: setup.cameraName).frame(width: 180) }
                    Picker("Típus", selection: setup.cameraKind) {
                        ForEach(CameraKind.allCases, id: \.self) { kind in
                            Text(cameraKindName(kind)).tag(kind)
                        }
                    }
                    .frame(width: 220)
                }
                HStack {
                    numberField("Szenzor szél.", value: setup.sensorWidthMM, suffix: "mm")
                    numberField("Szenzor mag.", value: setup.sensorHeightMM, suffix: "mm")
                    numberField("f-szám", value: setup.fNumber, suffix: "")
                    numberField("Hatékonyság", value: setup.relativeEfficiency, suffix: "×")
                }
                HStack {
                    numberField("Fókusz min.", value: setup.focalLengthMinMM, suffix: "mm")
                    numberField("Fókusz max.", value: setup.focalLengthMaxMM, suffix: "mm")
                    numberField("Alap fókusz", value: setup.defaultFocalLengthMM, suffix: "mm")
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func numberField(_ title: String, value: Binding<Double>, suffix: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 3) {
                TextField("", value: value, format: .number).frame(width: 62)
                if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
            }
        }
    }

    private var filtersPage: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Saját szűrők").font(.headline)
                    Text("Ugyanez a lista jelenik meg a capture-besorolásban és a session-konverzióban.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Egyedi szűrő") {
                        filterDrafts.append(FilterDraft(
                            databaseID: nil, manufacturer: "", model: "", name: "",
                            signalMode: .unknown, notes: "", createdAt: 0
                        ))
                    }
                } label: { Label("Szűrő hozzáadása", systemImage: "plus") }
            }
            .padding()

            if !filterInventoryReady {
                ContentUnavailableView {
                    Label("A szűrőlista nem tölthető be", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("A meglévő lista védelmében ez az oldal most nem menthető. Próbáld újra, vagy hagyd ki az oldalt.")
                } actions: {
                    Button("Betöltés újrapróbálása") {
                        Task { await reloadFilterInventory() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ScrollView {
                LazyVStack(spacing: 8) {
                    if filterDrafts.isEmpty {
                        ContentUnavailableView(
                            "Nincs mentett szűrő",
                            systemImage: "camera.filters",
                            description: Text("Ez rendben van szűrő nélküli OSC/DSLR munkához is.")
                        )
                    }
                    ForEach($filterDrafts) { $filter in
                        GroupBox {
                            HStack {
                                TextField("Gyártó", text: $filter.manufacturer)
                                TextField("Modell", text: $filter.model)
                                TextField("Saját név", text: $filter.name)
                                Picker("Fénysáv", selection: $filter.signalMode) {
                                    ForEach(SignalMode.allCases, id: \.self) { mode in
                                        Text(mode.displayNameHU).tag(mode)
                                    }
                                }
                                Button(role: .destructive) {
                                    filterDrafts.removeAll { $0.id == filter.id }
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding([.horizontal, .bottom])
            } }
        }
    }

    private var qualityPage: some View {
        Form {
            Section("Keretpontozás") {
                Stepper("Párhuzamos feldolgozók: \(ratingWorkers)", value: $ratingWorkers, in: 1...16)
                LabeledContent("Kiugró z-küszöb") {
                    TextField("", value: $outlierZScore, format: .number).frame(width: 90)
                }
                LabeledContent("Siril útvonal") { TextField("", text: $sirilPath) }
            }
            Section {
                Text("A Siril nélkül is van natív pontozás, de FWHM nem készül. A kiugró jelzés javaslat; az elfogadás/elvetés mindig a te döntésed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var integrationPage: some View {
        Form {
            Section("Elérhető, jó minőségű referencia") {
                numberField("Alapidő", value: $integrationRule.baseHours, suffix: "óra")
                numberField("Referencia f-szám", value: $integrationRule.referenceFNumber, suffix: "")
                numberField("Referencia hatékonyság", value: $integrationRule.referenceEfficiency, suffix: "×")
                HStack {
                    numberField("APS-C szélesség", value: $integrationRule.referenceSensorWidthMM, suffix: "mm")
                    numberField("APS-C magasság", value: $integrationRule.referenceSensorHeightMM, suffix: "mm")
                }
                numberField(
                    "Referencia felületi fényesség",
                    value: $integrationRule.referenceSurfaceBrightnessMagPerArcsec2,
                    suffix: "mag/arcsec²"
                )
            }
            Section("Célpontnehézség korlátja") {
                HStack {
                    numberField("Minimum", value: $integrationRule.minimumTargetFactor, suffix: "×")
                    numberField("Maximum", value: $integrationRule.maximumTargetFactor, suffix: "×")
                }
                Text("Gyári alap: 10 óra APS-C f/5 setupon, 22,0 mag/arcsec² átlagos felületi fényességnél. A katalógus magnitúdójából és méretéből becsült célpontszorzó 0,5–3× közé van fogva, így a referencia 5–30 óra között marad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Ez tervezési alap, nem tudományos SNR-garancia. Egy explicit goal: címke mindig felülírja.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var reviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mentés előtti ellenőrzés").font(.title2.bold())
                reviewRow(.location, text: manualSite ? "\(siteName) · \(latitude), \(longitude)" : "Automatikus FITS-helyszín")
                reviewRow(.equipment, text: "\(setups.count) setup · \(setups.first(where: \.isDefault)?.name ?? "nincs alapértelmezett")")
                reviewRow(.filters, text: "\(filterDrafts.count) saját szűrő")
                reviewRow(.quality, text: "\(ratingWorkers) worker · z=\(String(format: "%.1f", outlierZScore))")
                reviewRow(.integration, text: String(
                    format: "%.1f óra · f/%.1f · μ %.1f mag/arcsec² · célpont %.1f–%.1f×",
                    integrationRule.baseHours, integrationRule.referenceFNumber,
                    integrationRule.referenceSurfaceBrightnessMagPerArcsec2,
                    integrationRule.minimumTargetFactor, integrationRule.maximumTargetFactor
                ))
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Text("A kihagyott oldalak meglévő beállításai érintetlenek maradnak.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(26)
        }
    }

    private func reviewRow(_ item: Step, text: String) -> some View {
        HStack {
            Image(systemName: skipped.contains(item) ? "forward.fill" : item.symbol)
                .frame(width: 28).foregroundStyle(skipped.contains(item) ? .secondary : Color.accentColor)
            VStack(alignment: .leading) {
                Text(item.title).fontWeight(.semibold)
                Text(skipped.contains(item) ? "Kihagyva · a meglévő érték marad" : text)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var footer: some View {
        HStack {
            if step == .welcome {
                Button("Most kihagyom") { onSkipAll() }
            } else if step != .review {
                Button("Ezt az oldalt kihagyom") {
                    skipped.insert(step)
                    goForward()
                }
            }
            Spacer()
            if step != .welcome {
                Button("Előző") { goBack() }
            }
            if step == .review {
                Button("Beállítások alkalmazása") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Következő") {
                    skipped.remove(step)
                    goForward()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(step == .filters && !filterInventoryReady)
            }
        }
        .padding(16)
    }

    private func goForward() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        errorText = nil
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
        errorText = nil
    }

    private func finish() {
        do {
            var config = baseConfig
            if !skipped.contains(.location) {
                if manualSite {
                    let name = siteName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, let lat = Self.parseNumber(latitude), let lon = Self.parseNumber(longitude),
                          (-90...90).contains(lat), (-180...180).contains(lon)
                    else { throw WizardError.message("A helyszín neve és érvényes koordinátái szükségesek.") }
                    config.sites = [SiteProfile(name: name, latitudeDeg: lat, longitudeDeg: lon, isDefault: true)]
                    config.site = SiteRule(latitudeDeg: lat, longitudeDeg: lon)
                } else {
                    config.sites = []
                    config.site = SiteRule()
                }
                config.weather.enabled = weatherEnabled
            }
            if !skipped.contains(.equipment) {
                for setup in setups { try setup.validate() }
                var normalized = setups
                if !normalized.isEmpty, !normalized.contains(where: \.isDefault) { normalized[0].isDefault = true }
                config.imagingSetups = normalized
            }
            if !skipped.contains(.quality) {
                config.rating.workers = ratingWorkers
                config.rating.outlierZScore = outlierZScore
                config.rating.sirilPath = sirilPath
            }
            if !skipped.contains(.integration) {
                guard integrationRule.baseHours > 0,
                      integrationRule.referenceSensorWidthMM > 0,
                      integrationRule.referenceSensorHeightMM > 0,
                      integrationRule.referenceFNumber > 0,
                      integrationRule.referenceEfficiency > 0,
                      integrationRule.referenceSurfaceBrightnessMagPerArcsec2 > 0,
                      integrationRule.minimumTargetFactor > 0,
                      integrationRule.maximumTargetFactor >= integrationRule.minimumTargetFactor
                else { throw WizardError.message("A célidő referenciaértékei pozitívak és növekvő korlátúak legyenek.") }
                config.integrationReference = integrationRule
            }

            let filters: [FilterProfileRecord]? = skipped.contains(.filters)
                ? nil
                : try filterDrafts.map(Self.filterRecord)
            if appState.applyOnboarding(config: config, filters: filters) { onFinished() }
            else { errorText = appState.lastError ?? "A beállítások mentése sikertelen." }
        } catch let error as WizardError {
            errorText = error.text
        } catch let error as ImagingSetupValidationError {
            errorText = "Hibás setup-adat: \(error)"
        } catch {
            errorText = "\(error)"
        }
    }

    private func loadDraft() async {
        let inventory = await appState.loadFilterProfilesForOnboarding()
        guard !Task.isCancelled else { return }
        baseConfig = appState.config
        if let site = SiteProfile.defaultSite(in: appState.config.sites) {
            manualSite = true
            siteName = site.name
            latitude = String(format: "%.4f", site.latitudeDeg)
            longitude = String(format: "%.4f", site.longitudeDeg)
        } else {
            manualSite = false
            latitude = appState.resolvedSite.latitudeDeg.map { String(format: "%.4f", $0) } ?? ""
            longitude = appState.resolvedSite.longitudeDeg.map { String(format: "%.4f", $0) } ?? ""
        }
        weatherEnabled = appState.config.weather.enabled
        setups = appState.config.imagingSetups
        if let inventory {
            filterDrafts = inventory.map(Self.filterDraft)
            filterInventoryReady = true
        } else {
            filterDrafts = []
            filterInventoryReady = false
            skipped.insert(.filters)
            errorText = appState.lastError ?? "A szűrőlista nem tölthető be; az oldal kihagyva marad."
        }
        ratingWorkers = appState.config.rating.workers
        outlierZScore = appState.config.rating.outlierZScore
        sirilPath = appState.config.rating.sirilPath
        integrationRule = appState.config.integrationReference
        loaded = true
    }

    private func reloadFilterInventory() async {
        guard let inventory = await appState.loadFilterProfilesForOnboarding() else {
            errorText = appState.lastError ?? "A szűrőlista továbbra sem tölthető be."
            return
        }
        filterDrafts = inventory.map(Self.filterDraft)
        filterInventoryReady = true
        skipped.remove(.filters)
        errorText = nil
    }

    private func addSetup(_ setup: ImagingSetupProfile) {
        var copy = setup
        copy.id = UUID().uuidString
        if setups.isEmpty { copy.isDefault = true }
        else { copy.isDefault = false }
        setups.append(copy)
    }

    private func removeSetup(_ id: String) {
        let removedDefault = setups.first { $0.id == id }?.isDefault == true
        setups.removeAll { $0.id == id }
        if removedDefault, !setups.isEmpty { setups[0].isDefault = true }
    }

    private func setDefaultSetup(_ id: String) {
        for index in setups.indices { setups[index].isDefault = setups[index].id == id }
    }

    private func cameraKindName(_ kind: CameraKind) -> String {
        switch kind {
        case .dedicatedAstro: "Dedikált asztrokamera"
        case .unmodifiedColor: "Nem modifikált színes"
        case .modifiedColor: "Asztromodifikált színes"
        case .monochrome: "Monokróm"
        }
    }

    private static func apsCBaseTemplate() -> ImagingSetupProfile {
        ImagingSetupProfile(
            id: "onboarding-apsc", name: "APS-C alapsetup", cameraName: "",
            cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.6,
            focalLengthMinMM: 200, focalLengthMaxMM: 200, defaultFocalLengthMM: 200,
            fNumber: 5, relativeEfficiency: 1, isDefault: true
        )
    }

    private static func fullFrameBaseTemplate() -> ImagingSetupProfile {
        ImagingSetupProfile(
            id: "onboarding-full-frame", name: "Full frame alapsetup", cameraName: "",
            cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
            focalLengthMinMM: 50, focalLengthMaxMM: 50, defaultFocalLengthMM: 50,
            fNumber: 4, relativeEfficiency: 1
        )
    }

    private static func filterDraft(_ record: FilterProfileRecord) -> FilterDraft {
        FilterDraft(
            databaseID: record.id, manufacturer: record.manufacturer ?? "", model: record.model ?? "",
            name: record.name ?? "", signalMode: record.signalMode, notes: record.notes ?? "",
            createdAt: record.createdAt
        )
    }

    private static func filterRecord(_ draft: FilterDraft) throws -> FilterProfileRecord {
        let record = FilterProfileRecord(
            id: draft.databaseID,
            manufacturer: draft.manufacturer,
            model: draft.model,
            name: draft.name,
            signalMode: draft.signalMode,
            notes: draft.notes,
            createdAt: draft.createdAt
        )
        return try FilterProfileValidator.prepared(record)
    }

    private static func parseNumber(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
}

private enum WizardError: Error {
    case message(String)
    var text: String {
        switch self { case .message(let text): text }
    }
}
