import AppKit
import AstroApplication
import PDFKit
import SwiftUI

public struct NightBriefingView: View {
    @State private var store: NightBriefingStore
    @State private var customChecklistTitle = ""
    @State private var otherNightDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()

    public init(
        rootURL: URL?,
        seed: NightBriefingSeed? = nil,
        applicationSupport: URL? = nil,
        caches: URL? = nil
    ) {
        _store = State(initialValue: NightBriefingStore(
            libraryRoot: rootURL,
            seed: seed,
            applicationSupport: applicationSupport,
            caches: caches
        ))
    }

    public var body: some View {
        Group {
            if store.hasStarted {
                editor
            } else {
                start
            }
        }
        .navigationTitle("Éjszakai briefing")
        .astroSectionMarker("v2.detail.briefing", label: "Éjszakai briefing")
        .task { await store.loadRecent() }
    }

    private var start: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                    Text("Vidd magaddal az egész éjszaka tervét")
                        .font(.largeTitle.weight(.semibold))
                    Text("Az AstroTool végigvezet a helyszínen, a célpontokon, a capture-beállításokon és a B terven. A végén egy telefonon is olvasható PDF készül; az eredeti fotóidat ez a folyamat nem módosítja és nem törli.")
                        .font(.title3)
                        .foregroundStyle(AstroTokens.Color.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: AstroTokens.Spacing.standard) {
                    startChoice(
                        identifier: "v2.briefing.start.today",
                        title: "A ma estét szeretném megtervezni",
                        detail: "A mai dátummal indulunk. Minden más adatot te erősítesz meg.",
                        icon: "moon.stars.fill",
                        action: store.startTonight
                    )
                    startChoice(
                        identifier: "v2.briefing.start.other",
                        title: "Másik dátumra készülök",
                        detail: "Válaszd ki alább az estét; később bármikor átírhatod.",
                        icon: "calendar",
                        action: { store.start(date: otherNightDate) }
                    )
                    DatePicker(
                        "Melyik estére készülsz?",
                        selection: $otherNightDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.field)
                    .accessibilityIdentifier("v2.briefing.other-date")
                    startChoice(
                        identifier: "v2.briefing.start.continue",
                        title: "Egy korábbi briefinget folytatok",
                        detail: store.recentDrafts.isEmpty
                            ? "Még nincs mentett briefing ezen a gépen."
                            : "A legutóbbi mentett változatból folytatjuk; a régi változat megmarad.",
                        icon: "clock.arrow.circlepath",
                        action: {
                            if let latest = store.recentDrafts.first { store.continueDraft(latest) }
                        },
                        disabled: store.recentDrafts.isEmpty
                    )
                }
                .frame(maxWidth: 720)

                Label("A mentés mindig új változatot készít. Meglévő briefinget, könyvtárat vagy fotót nem ír felül.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(AstroTokens.Color.inkDim)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(AstroTokens.Spacing.spacious)
        }
    }

    private func startChoice(
        identifier: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        icon: String,
        action: @escaping () -> Void,
        disabled: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AstroTokens.Spacing.standard) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(AstroTokens.Color.accent)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(AstroTokens.Color.ink)
                    Text(detail).font(.callout).foregroundStyle(AstroTokens.Color.inkDim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(AstroTokens.Color.inkFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .astroRaisedSurface()
    }

    private var editor: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                stepRail
                    .frame(width: 236)
                Divider()
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Éjszakai briefing").font(.title2.weight(.semibold))
                Text("Egy nyugodt terv a terepre — mobilon és papíron is.")
                    .font(.callout).foregroundStyle(AstroTokens.Color.inkDim)
            }
            Spacer()
            readinessBadge
            Button("Változat mentése") {
                Task { await store.saveRevisionShowingErrors() }
            }
            .accessibilityIdentifier("v2.briefing.save-revision")
            .disabled(store.isWorking)
            .help("Új mentést készít; korábbi változatot nem ír felül.")
        }
        .padding(.horizontal, AstroTokens.Spacing.section)
        .padding(.vertical, AstroTokens.Spacing.standard)
    }

    private var readinessBadge: some View {
        let readiness = store.document.readiness
        return Label {
            switch readiness {
            case .ready: Text("Indulásra kész")
            case .attention: Text("Érdemes átnézni")
            case .incomplete: Text("Még hiányos")
            }
        } icon: {
            Image(systemName: readiness == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(readiness == .ready ? AstroTokens.Color.ok : AstroTokens.Color.attention)
        .accessibilityIdentifier("v2.briefing.readiness")
    }

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("AZ ÉJSZAKA ÚTVONALA")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AstroTokens.Color.inkFaint)
                .padding(.bottom, AstroTokens.Spacing.standard)
            ForEach(NightBriefingStep.allCases) { step in
                Button { store.currentStep = step } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            ZStack {
                                Circle()
                                    .fill(step == store.currentStep ? AstroTokens.Color.accent : step.rawValue < store.currentStep.rawValue ? AstroTokens.Color.ok : AstroTokens.Color.edge)
                                    .frame(width: 28, height: 28)
                                Text(stepNumber(step), format: .number)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(step.rawValue <= store.currentStep.rawValue ? AstroTokens.Color.ink : AstroTokens.Color.inkDim)
                            }
                            if step != .preview {
                                Rectangle()
                                    .fill(step.rawValue < store.currentStep.rawValue ? AstroTokens.Color.ok : AstroTokens.Color.edge)
                                    .frame(width: 2, height: 36)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stepTitle(step)).font(.headline)
                            Text(stepHint(step)).font(.caption).foregroundStyle(AstroTokens.Color.inkDim)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("v2.briefing.step.\(step.rawValue + 1)")
            }
            Spacer()
            Button("Újrakezdés") { store.hasStarted = false }
                .buttonStyle(.link)
                .help("A jelenlegi terv csak akkor marad meg, ha előbb változatot mentesz.")
        }
        .padding(AstroTokens.Spacing.section)
        .background(.regularMaterial)
    }

    private func stepTitle(_ step: NightBriefingStep) -> LocalizedStringKey {
        switch step {
        case .basics: "Alapok"
        case .targets: "Célpontok"
        case .capture: "Capture-terv"
        case .checklist: "Checklist és B terv"
        case .preview: "Ellenőrzés és export"
        }
    }

    private func stepNumber(_ step: NightBriefingStep) -> Int {
        step.rawValue + 1
    }

    private func stepHint(_ step: NightBriefingStep) -> LocalizedStringKey {
        switch step {
        case .basics: "Mikor, hol, mivel"
        case .targets: "Mi következik mikor"
        case .capture: "Mit állíts be"
        case .checklist: "Mit vigyél, mi legyen ha…"
        case .preview: "Amit magaddal viszel"
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch store.currentStep {
                    case .basics: basicsStep
                    case .targets: targetsStep
                    case .capture: captureStep
                    case .checklist: checklistStep
                    case .preview: previewStep
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(AstroTokens.Spacing.spacious)
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack {
            if store.currentStep != .basics {
                Button("Vissza", action: store.goBack)
                    .accessibilityIdentifier("v2.briefing.back")
            }
            Spacer()
            if let message = store.message {
                Text(message).font(.callout).foregroundStyle(AstroTokens.Color.ok)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AstroTokens.Color.critical)
                    .accessibilityIdentifier("v2.briefing.persistence-error")
            }
            if store.currentStep != .preview {
                Button("Tovább", action: store.goForward)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("v2.briefing.next")
            }
        }
        .padding(AstroTokens.Spacing.standard)
    }

    private var basicsStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            stepHeading("Mikor és hol leszel?", "Csak azt írd be, amit valóban tudsz. A hiányzó időjárás vagy felszerelés látható marad a briefingben.")
            if let date = store.draft.nightDate {
                DatePicker("Az éjszaka dátuma", selection: Binding(get: { date }, set: { store.draft.nightDate = $0 }), displayedComponents: .date)
            }
            if let arrival = store.draft.arrival {
                DatePicker("Érkezés", selection: Binding(get: { arrival }, set: { store.draft.arrival = $0 }))
            }
            if let departure = store.draft.departure {
                DatePicker("Indulás haza", selection: Binding(get: { departure }, set: { store.draft.departure = $0 }))
            }
            TextField("Helyszín neve", text: siteName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("v2.briefing.site-name")
            TextField("Felszerelés rövid neve", text: setupName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("v2.briefing.setup-name")
            TextField("Várható tápidő órában", text: powerHours)
                .textFieldStyle(.roundedBorder)
            missingDataNotice
        }
    }

    private var siteName: Binding<String> {
        Binding(
            get: { store.draft.site?.name ?? "" },
            set: { value in
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                store.draft.site = clean.isEmpty ? nil : .init(id: clean.lowercased(), name: value)
            }
        )
    }

    private var setupName: Binding<String> {
        Binding(
            get: { store.draft.setup?.name ?? "" },
            set: { value in
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                store.draft.setup = clean.isEmpty ? nil : .init(id: clean.lowercased(), name: value)
            }
        )
    }

    private var powerHours: Binding<String> {
        Binding(
            get: { store.draft.powerRuntimeHours.map { String($0) } ?? "" },
            set: { store.draft.powerRuntimeHours = Double($0.replacingOccurrences(of: ",", with: ".")) }
        )
    }

    private var missingDataNotice: some View {
        Label("Az időjárás most nincs automatikusan kitöltve. Ez nem hiba: indulás előtt ellenőrizd egy általad megbízhatónak tartott forrásból. A forecast soha nem garancia.", systemImage: "cloud.sun")
            .font(.callout)
            .foregroundStyle(AstroTokens.Color.attention)
            .astroRaisedSurface()
    }

    private var targetsStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            stepHeading("Adj ritmust az éjszakának", "Az első célpont a fő terv. A tartalék opcionális, de sok bizonytalanságot levesz a válladról.")
            if store.draft.targets.isEmpty {
                ContentUnavailableView("Még nincs célpont", systemImage: "scope", description: Text("Az AstroTool nem talál ki helyetted célpontot. Add hozzá azt, amit valóban szeretnél fotózni."))
            }
            ForEach($store.draft.targets) { $target in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Célpont neve", text: $target.name)
                            .font(.headline)
                        Picker("Szerepe", selection: $target.role) {
                            Text("Fő célpont").tag(BriefingTargetRole.primary)
                            Text("Tartalék").tag(BriefingTargetRole.backup)
                        }
                        .frame(width: 180)
                        Button(role: .destructive) { store.removeTarget(id: target.id) } label: {
                            Label("Eltávolítás a tervből", systemImage: "minus.circle")
                        }
                        .help("Csak ebből a még nem exportált tervből veszi ki; fotót nem töröl.")
                    }
                    DatePicker("Kezdés", selection: $target.start)
                    DatePicker("Befejezés", selection: $target.end)
                    if target.end <= target.start {
                        Label("A befejezésnek később kell lennie a kezdésnél.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AstroTokens.Color.critical)
                    }
                }
                .astroRaisedSurface()
            }
            Button("Célpont hozzáadása", systemImage: "plus", action: store.addTarget)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v2.briefing.add-target")
        }
    }

    private var captureStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            stepHeading("Mit állíts be a capture-höz?", "A mezők kihagyhatók. Ha valami üres, az export nem fog helyette értéket kitalálni.")
            if store.draft.targets.isEmpty {
                ContentUnavailableView("Előbb adj hozzá célpontot", systemImage: "camera.metering.unknown", description: Text("A capture-terv mindig egy konkrét célponthoz tartozik."))
            }
            ForEach($store.draft.targets) { $target in
                VStack(alignment: .leading, spacing: 12) {
                    Text(target.name.isEmpty ? "Névtelen célpont" : target.name).font(.headline)
                    HStack {
                        TextField("Szűrő", text: optionalString($target.capturePlan.filterName))
                        TextField("Expozíció (mp)", text: optionalDouble($target.capturePlan.exposureSeconds))
                        TextField("Képek száma", text: optionalInt($target.capturePlan.frameCount))
                    }
                    HStack {
                        TextField("Gain", text: optionalDouble($target.capturePlan.gain))
                        TextField("Offset", text: optionalDouble($target.capturePlan.offset))
                        TextField("Binning", text: optionalInt($target.capturePlan.binning))
                        TextField("Hőmérséklet (°C)", text: optionalDouble($target.capturePlan.temperatureCelsius))
                    }
                    if let integration = target.capturePlan.integrationSeconds {
                        Text("Tervezett összidő: \(integration / 3600, format: .number.precision(.fractionLength(1))) óra")
                            .font(.callout.monospacedDigit()).foregroundStyle(AstroTokens.Color.inkDim)
                    }
                    Label("A gain, offset, binning és hőmérséklet egyezzen a hozzájuk tartozó kalibrációs képekkel.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(AstroTokens.Color.inkDim)
                }
                .astroRaisedSurface()
            }
        }
    }

    private func optionalString(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func optionalDouble(_ value: Binding<Double?>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue.map { String($0) } ?? "" },
            set: { value.wrappedValue = Double($0.replacingOccurrences(of: ",", with: ".")) }
        )
    }

    private func optionalInt(_ value: Binding<Int?>) -> Binding<String> {
        Binding(get: { value.wrappedValue.map(String.init) ?? "" }, set: { value.wrappedValue = Int($0) })
    }

    private var checklistStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            stepHeading("Ami ne maradjon otthon — és a B terv", "Kapcsold ki azt, ami biztosan nem vonatkozik rád. A rövid magyarázatok megmaradnak a hordozható tervben.")
            ForEach($store.draft.checklist) { $section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.title).font(.headline)
                    ForEach($section.items) { $item in
                        Toggle(isOn: $item.isVisible) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                if let explanation = item.explanation {
                                    Text(verbatim: explanation).font(.caption).foregroundStyle(AstroTokens.Color.inkDim)
                                }
                            }
                        }
                    }
                }
                .astroRaisedSurface()
            }
            HStack {
                TextField("Saját checklist-elem", text: $customChecklistTitle)
                    .textFieldStyle(.roundedBorder)
                Button("Hozzáadás") {
                    store.addCustomChecklistItem(title: customChecklistTitle)
                    customChecklistTitle = ""
                }
                .disabled(customChecklistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .accessibilityIdentifier("v2.briefing.custom-checklist")
            VStack(alignment: .leading, spacing: 10) {
                Text("B terv").font(.title3.weight(.semibold))
                ForEach(store.document.contingencies) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title).font(.headline)
                        Text(verbatim: item.action).font(.callout).foregroundStyle(AstroTokens.Color.inkDim)
                    }
                }
            }
            .astroRaisedSurface()
            TextField("Saját megjegyzés az éjszakához", text: $store.draft.notes, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            stepHeading("Ezt viszed magaddal", "Nézd át úgy, mintha már a sötétben, csak a telefonodról olvasnád.")
            if !store.canExport {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Az exporthoz még ezt javítsd:", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(AstroTokens.Color.critical)
                    ForEach(store.document.issues.filter(\.blocksExport)) { issue in
                        Text("• \(issue.message)")
                    }
                }
                .astroRaisedSurface()
            } else {
                HStack {
                    Button("PDF mentése…") { export(.pdf) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.briefing.export.pdf")
                    Button("PDF + telefonos képek…") { export(.pdfAndPNG) }
                        .accessibilityIdentifier("v2.briefing.export.pdf-png")
                    Button("Csak képek…") { export(.pngOnly) }
                        .accessibilityIdentifier("v2.briefing.export.png")
                }
                Label("Az export csak új PDF-et és – ha kéred – új PNG-oldalakat hoz létre. Nem töröl, nem mozgat és nem ír felül semmit.", systemImage: "shield.lefthalf.filled")
                    .font(.callout).foregroundStyle(AstroTokens.Color.ok)
                Group {
                    if let data = store.previewPDF {
                        BriefingPDFPreview(data: data)
                            .frame(minHeight: 520)
                    } else if store.isWorking {
                        ProgressView("Előnézet készítése…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if let error = store.previewError {
                        VStack(spacing: AstroTokens.Spacing.standard) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(AstroTokens.Color.critical)
                            Button("Előnézet újrapróbálása", systemImage: "arrow.clockwise") {
                                Task { await store.makePreview() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        Button("Előnézet elkészítése", systemImage: "doc.richtext") {
                            Task { await store.makePreview() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .task(id: store.currentStep) {
            if store.currentStep == .preview { await store.makePreview() }
        }
    }

    private func export(_ format: BriefingExportFormat) {
        #if DEBUG
        if let testPath = uiTestExportPath {
            var destination = URL(fileURLWithPath: testPath)
            if format != .pngOnly, destination.pathExtension.lowercased() != "pdf" {
                destination.appendPathExtension("pdf")
            }
            Task { try? await store.export(to: destination, format: format) }
            return
        }
        #endif
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format == .pngOnly
            ? String(localized: "night-briefing-images")
            : String(localized: "night-briefing.pdf")
        if format != .pngOnly { panel.allowedContentTypes = [.pdf] }
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if format != .pngOnly, destination.pathExtension.lowercased() != "pdf" {
            destination.appendPathExtension("pdf")
        }
        Task {
            do {
                _ = try await store.export(to: destination, format: format)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Nem sikerült biztonságosan exportálni")
                alert.informativeText = String(localized: "Válassz új fájlnevet vagy üres célmappát. Meglévő fájlt az AstroTool nem ír felül.")
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    #if DEBUG
    private var uiTestExportPath: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-UITestBriefingExportPath") else { return nil }
        let value = arguments.index(after: index)
        guard value < arguments.endIndex else { return nil }
        return arguments[value]
    }
    #endif

    private func stepHeading(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(detail).font(.title3).foregroundStyle(AstroTokens.Color.inkDim)
        }
    }
}

private struct BriefingPDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data {
            view.document = PDFDocument(data: data)
        }
    }
}
