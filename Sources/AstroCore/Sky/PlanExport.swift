import Foundation

/// Tonight's plan export (R11-T6/F18a): one shared rendering used by the
/// CLI's `plan --out PATH|-` and the app's "Terv exportálása…" toolbar menu
/// (both the "CSV-fájlba…" and "Vágólapra" items) -- pure string rendering
/// only, never touches the filesystem/pasteboard itself, so the exact same
/// code path is exercised by tests and both real call sites, and the two
/// surfaces can never quietly disagree on columns/formatting.
public enum PlanExport {
    /// CSV header -- exact column order/names the spec calls for:
    /// `target, ra_deg, dec_deg, window_start, window_end, max_alt_deg,
    /// moon_illum, verdict, filter_suggestion`.
    public static let csvHeader =
        "target,ra_deg,dec_deg,window_start,window_end,max_alt_deg,moon_illum,verdict,filter_suggestion"

    /// One CSV row per plan, in `plans`' own order -- callers (`cmdPlan`:
    /// tonight's whole plan; `TonightPage`: the selected row, else the "ma
    /// jó" rows, else every row -- see its own selection rule) decide which
    /// subset/order to pass in. `target` is the raw library/folder name
    /// (not `displayName`) -- a script piping this back into e.g. `stats
    /// --target` needs the canonical key, not the human-facing label.
    public static func renderCSV(_ plans: [TargetPlan]) -> String {
        var lines = [csvHeader]
        for plan in plans {
            lines.append(csvRow(plan).map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvRow(_ plan: TargetPlan) -> [String] {
        let (start, end) = windowParts(plan.visibleWindowLocal)
        return [
            plan.target,
            plan.raDeg.map { String($0) } ?? "",
            plan.decDeg.map { String($0) } ?? "",
            start ?? "",
            end ?? "",
            plan.maxAltitudeDeg.map { String(format: "%.1f", $0) } ?? "",
            plan.moonIlluminationPercent.map { String(format: "%.1f", $0) } ?? "",
            plan.verdict,
            filterSuggestion(plan) ?? "",
        ]
    }

    // MARK: - Clipboard (app-only "Vágólapra" menu item)

    /// One tab-separated line per plan (pastes cleanly into a spreadsheet):
    /// display name, RA/Dec (hour/degree HMS/DMS -- the spec's own wording),
    /// visibility window, and the recommended filter when the target has
    /// filter goals. Unlike `renderCSV`, this is never parsed back by a
    /// script, so it favors the human-facing `displayName`/HMS-DMS/`"-"`
    /// glyph over the CSV's raw/decimal/empty-field conventions.
    public static func renderClipboardText(_ plans: [TargetPlan]) -> String {
        var lines = ["Célpont\tRA\tDec\tLáthatósági ablak\tJavasolt szűrő"]
        for plan in plans {
            let ra = plan.raDeg.map(raHMS) ?? "-"
            let dec = plan.decDeg.map(decDMS) ?? "-"
            let window = plan.visibleWindowLocal ?? "-"
            let filter = filterSuggestion(plan) ?? "-"
            lines.append("\(plan.displayName)\t\(ra)\t\(dec)\t\(window)\t\(filter)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared helpers

    /// `FilterAdvisor.chipText` off this plan's own `filterAdvice`/
    /// `filterGoals` -- the exact same text `TonightPage`'s "Szűrő ma"
    /// column chip shows, so the exported plan and the on-screen table never
    /// disagree about what "today's suggested filter" says.
    private static func filterSuggestion(_ plan: TargetPlan) -> String? {
        guard let advice = plan.filterAdvice else { return nil }
        return FilterAdvisor.chipText(advice: advice, filterGoals: plan.filterGoals)
    }

    /// Splits `NightSweep.visibleWindowLocal`'s `"HH:mm–HH:mm"` shape (an EN
    /// DASH, not a hyphen) into its two halves -- `(nil, nil)` when there's
    /// no window at all.
    private static func windowParts(_ window: String?) -> (String?, String?) {
        guard let window else { return (nil, nil) }
        let parts = window.components(separatedBy: "–")
        guard parts.count == 2 else { return (window, nil) }
        return (parts[0], parts[1])
    }

    /// Standard CSV field escaping: wrap in quotes (doubling any embedded
    /// quote) when the field contains a comma, a quote, or a newline;
    /// otherwise emit as-is. Same rule `AcquisitionExport`'s own private
    /// `csvField` already follows -- kept as its own copy here rather than a
    /// shared export since there's no common CSV-writing type yet.
    private static func csvField(_ raw: String) -> String {
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `"05h 34m 32.0s"` -- right ascension in hours/minutes/seconds,
    /// normalized to `[0, 360)` degrees before the /15 hour conversion. Same
    /// formula `TargetReport.raHMS`/`TDFormat.raHMS` already use (both are
    /// private to their own module -- kept as its own small copy here, same
    /// "two independent private copies across the app/core boundary" stance
    /// those two already follow).
    private static func raHMS(_ deg: Double) -> String {
        var normalized = deg.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let hours = normalized / 15.0
        let h = Int(hours)
        let minutesFull = (hours - Double(h)) * 60
        let m = Int(minutesFull)
        let s = (minutesFull - Double(m)) * 60
        return String(format: "%02dh %02dm %04.1fs", h, m, s)
    }

    /// `"+22° 00' 52.0\""` -- declination in signed degrees/arcmin/arcsec.
    private static func decDMS(_ deg: Double) -> String {
        let sign = deg < 0 ? "-" : "+"
        let absDeg = abs(deg)
        let d = Int(absDeg)
        let minutesFull = (absDeg - Double(d)) * 60
        let m = Int(minutesFull)
        let s = (minutesFull - Double(m)) * 60
        return "\(sign)\(String(format: "%02d° %02d' %04.1f\"", d, m, s))"
    }
}
