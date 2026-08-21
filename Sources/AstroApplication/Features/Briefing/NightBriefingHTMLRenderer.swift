import Foundation

public struct NightBriefingHTMLRenderer: Sendable {
    public init() {}

    public func render(_ document: NightBriefingDocument) -> String {
        let draft = document.draft
        let copy = Copy(draft.language)
        let timelineRows = draft.targets.map { target in
            "<tr><td><strong>\(escape(target.name))</strong><br><span class=\"role\">\(copy.role(target.role))</span></td><td>\(time(target.start, draft.language))–\(time(target.end, draft.language))</td><td>\(capture(target.capturePlan, copy))</td></tr>"
        }.joined()
        let targetPages = draft.targets.map { target in
            """
            <section class="page-break target">
              <p class="eyebrow">\(copy.targetSheet)</p><h2>\(escape(target.name))</h2>
              <div class="facts"><div><span>\(copy.plannedWindow)</span><strong>\(time(target.start, draft.language))–\(time(target.end, draft.language))</strong></div><div><span>\(copy.roleLabel)</span><strong>\(copy.role(target.role))</strong></div></div>
              <h3>\(copy.capturePlan)</h3><p>\(capture(target.capturePlan, copy))</p>
              \(target.warnings.isEmpty ? "" : "<div class=\"warning\">\(target.warnings.map(escape).joined(separator: "<br>"))</div>")
            </section>
            """
        }.joined()
        let checklist = draft.checklist.map { section in
            let items = section.items.filter(\.isVisible).map { item in
                "<li><span class=\"box\">□</span><div><strong>\(escape(item.title))</strong>\(item.explanation.map { "<small>\(escape($0))</small>" } ?? "")</div></li>"
            }.joined()
            return "<div class=\"check-section\"><h3>\(escape(section.title))</h3><ul class=\"checklist\">\(items)</ul></div>"
        }.joined()
        let contingencies = document.contingencies.map {
            "<article class=\"contingency\"><h3>\(escape($0.title))</h3><p>\(escape($0.action))</p></article>"
        }.joined()
        let issues = document.issues.isEmpty ? "" : "<div class=\"warning\"><strong>\(copy.checkBeforeLeaving)</strong><ul>\(document.issues.map { "<li>\(escape($0.message))</li>" }.joined())</ul></div>"

        return """
        <!doctype html><html lang="\(draft.language.rawValue)"><head><meta charset="utf-8"><style>
        @page { size: A4 portrait; margin: 14mm 14mm 16mm; }
        :root { color-scheme: light; } * { box-sizing: border-box; }
        body { margin: 0; color: #172033; background: #fff; font-size: 11pt; font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; line-height: 1.45; }
        body > section { padding: 36px; width: 100%; }
        h1 { font-size: 30pt; line-height: 1.08; margin: 8mm 0 4mm; } h2 { font-size: 21pt; margin: 0 0 5mm; } h3 { font-size: 13pt; margin: 4mm 0 2mm; }
        p { margin: 0 0 3mm; } .eyebrow { color: #315f9e; text-transform: uppercase; letter-spacing: .09em; font-size: 9pt; font-weight: 700; }
        .page-break { page-break-before: always; } .cover { display: flex; flex-direction: column; } .cover footer { margin-top: auto; color: #596579; }
        .status { display: inline-block; padding: 2mm 4mm; border-radius: 99px; background: #e6eefb; font-weight: 700; }
        .facts { display: grid; grid-template-columns: repeat(2, 1fr); gap: 3mm; margin: 5mm 0; } .facts div { border: 1px solid #cbd5e1; padding: 3mm; border-radius: 3mm; }
        .facts span { display: block; color: #596579; font-size: 9pt; margin-bottom: 1mm; } table { width: 100%; border-collapse: collapse; margin-top: 4mm; }
        th, td { text-align: left; vertical-align: top; border-bottom: 1px solid #d8dee8; padding: 3mm 2mm; } th { color: #596579; font-size: 9pt; }
        .role { color: #596579; font-size: 9pt; } svg { display: block; width: 100%; margin: 4mm 0; } .warning { padding: 4mm; border-left: 4px solid #b35c00; background: #fff4df; margin: 4mm 0; }
        .check-section, .contingency { break-inside: avoid; } .checklist { list-style: none; padding: 0; } .checklist li { display: flex; gap: 3mm; margin: 0 0 3mm; }
        .box { font-size: 16pt; line-height: 1; } small { display: block; color: #596579; margin-top: .5mm; } .notes-lines { height: 145mm; background: repeating-linear-gradient(to bottom, #fff 0, #fff 9mm, #cbd5e1 9mm, #cbd5e1 9.3mm); }
        </style></head><body>
        <section class="cover"><p class="eyebrow">AstroTool 4</p><h1>\(copy.title)</h1><p>\(date(draft.nightDate, draft.language)) · \(escape(draft.site?.name ?? copy.notProvided))</p><div class="facts"><div><span>\(copy.setup)</span><strong>\(escape(draft.setup?.name ?? copy.notProvided))</strong></div><div><span>\(copy.weather)</span><strong>\(weather(draft.weather, copy))</strong></div><div><span>\(copy.arrival)</span><strong>\(optionalTime(draft.arrival, draft.language, copy))</strong></div><div><span>\(copy.departure)</span><strong>\(optionalTime(draft.departure, draft.language, copy))</strong></div></div><p><span class="status">\(copy.readiness(document.readiness))</span></p>\(issues)<footer>\(copy.preparedAtHome)</footer></section>
        <section class="page-break"><p class="eyebrow">02</p><h2>\(copy.atAGlance)</h2><h3>\(copy.timeline)</h3>\(NightBriefingSVGRenderer().timeline(targets: draft.targets))<table><thead><tr><th>\(copy.target)</th><th>\(copy.plannedWindow)</th><th>\(copy.capturePlan)</th></tr></thead><tbody>\(timelineRows)</tbody></table></section>
        \(targetPages)
        <section class="page-break"><p class="eyebrow">\(copy.fieldReady)</p><h2>\(copy.equipmentAndCalibration)</h2><p><strong>\(copy.setup):</strong> \(escape(draft.setup?.name ?? copy.notProvided))</p><p>\(copy.calibrationReminder)</p><h2>\(copy.checklist)</h2>\(checklist)</section>
        <section class="page-break"><p class="eyebrow">\(copy.whenThingsChange)</p><h2>\(copy.backupPlan)</h2>\(contingencies)</section>
        <section class="page-break"><p class="eyebrow">\(copy.inTheField)</p><h2>\(copy.fieldNotes)</h2>\(draft.notes.isEmpty ? "" : "<p>\(escape(draft.notes))</p>")<div class="notes-lines"></div></section>
        </body></html>
        """
    }

    private func capture(_ plan: BriefingCapturePlan, _ copy: Copy) -> String {
        var parts: [String] = []
        if let filter = plan.filterName { parts.append(escape(filter)) }
        if let exposure = plan.exposureSeconds, let count = plan.frameCount {
            parts.append("\(count) × \(format(exposure)) s")
        } else if let exposure = plan.exposureSeconds { parts.append("\(format(exposure)) s") }
        if let gain = plan.gain { parts.append("gain \(format(gain))") }
        if let integration = plan.integrationSeconds { parts.append("\(copy.integration) \(format(integration / 3_600)) h") }
        return parts.isEmpty ? copy.notProvided : parts.joined(separator: " · ")
    }

    private func weather(_ state: BriefingDataState<BriefingWeatherSummary>, _ copy: Copy) -> String {
        switch state {
        case .known(let value): escape(value.summary)
        case .missing(let reason): escape(reason)
        case .stale(let value, _): "\(escape(value.summary)) · \(copy.stale)"
        }
    }

    private func date(_ value: Date?, _ language: BriefingDocumentLanguage) -> String {
        guard let value else { return language == .hu ? "Nincs dátum" : "No date" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: language == .hu ? "hu_HU" : "en_GB")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        return escape(formatter.string(from: value))
    }

    private func optionalTime(_ value: Date?, _ language: BriefingDocumentLanguage, _ copy: Copy) -> String {
        value.map { time($0, language) } ?? copy.notProvided
    }

    private func time(_ value: Date, _ language: BriefingDocumentLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .hu ? "hu_HU" : "en_GB")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: value)
    }

    private func format(_ value: Double) -> String { String(format: value.rounded() == value ? "%.0f" : "%.1f", value) }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: ":", with: "&#58;")
    }

    private struct Copy {
        let language: BriefingDocumentLanguage
        init(_ language: BriefingDocumentLanguage) { self.language = language }
        var title: String { language == .hu ? "Éjszakai briefing" : "Night briefing" }
        var atAGlance: String { language == .hu ? "Este röviden" : "Tonight at a glance" }
        var timeline: String { language == .hu ? "Idővonal" : "Timeline" }
        var checklist: String { "Checklist" }
        var backupPlan: String { language == .hu ? "B terv" : "Backup plan" }
        var fieldNotes: String { language == .hu ? "Terepi jegyzetek" : "Field notes" }
        var setup: String { language == .hu ? "Felszerelés" : "Equipment" }
        var weather: String { language == .hu ? "Időjárás" : "Weather" }
        var arrival: String { language == .hu ? "Érkezés" : "Arrival" }
        var departure: String { language == .hu ? "Távozás" : "Departure" }
        var target: String { language == .hu ? "Célpont" : "Target" }
        var targetSheet: String { language == .hu ? "Célpontlap" : "Target sheet" }
        var plannedWindow: String { language == .hu ? "Tervezett ablak" : "Planned window" }
        var roleLabel: String { language == .hu ? "Szerep" : "Role" }
        var capturePlan: String { language == .hu ? "Capture-terv" : "Capture plan" }
        var integration: String { language == .hu ? "integráció" : "integration" }
        var notProvided: String { language == .hu ? "Nincs megadva" : "Not provided" }
        var stale: String { language == .hu ? "elavult adat" : "stale data" }
        var checkBeforeLeaving: String { language == .hu ? "Indulás előtt ellenőrizd" : "Check before leaving" }
        var preparedAtHome: String { language == .hu ? "Otthon készült. A forecast és a terv nem helyettesíti a helyszíni ellenőrzést." : "Prepared at home. Forecast and plan do not replace field checks." }
        var fieldReady: String { language == .hu ? "Helyszínre készen" : "Field ready" }
        var equipmentAndCalibration: String { language == .hu ? "Felszerelés és kalibráció" : "Equipment and calibration" }
        var calibrationReminder: String { language == .hu ? "A gain, offset, binning, hőmérséklet és szűrő egyezzen a kalibrációs képekkel." : "Match gain, offset, binning, temperature and filter to calibration frames." }
        var whenThingsChange: String { language == .hu ? "Ha változik az este" : "When the night changes" }
        var inTheField: String { language == .hu ? "A helyszínen" : "In the field" }
        func role(_ role: BriefingTargetRole) -> String {
            switch (language, role) {
            case (.hu, .primary): "Elsődleges"
            case (.hu, .backup): "Tartalék"
            case (.en, .primary): "Primary"
            case (.en, .backup): "Backup"
            }
        }
        func readiness(_ readiness: BriefingReadiness) -> String {
            switch (language, readiness) {
            case (.hu, .ready): "Kész"
            case (.hu, .attention): "Ellenőrizd"
            case (.hu, .incomplete): "Hiányos"
            case (.en, .ready): "Ready"
            case (.en, .attention): "Check"
            case (.en, .incomplete): "Incomplete"
            }
        }
    }
}
