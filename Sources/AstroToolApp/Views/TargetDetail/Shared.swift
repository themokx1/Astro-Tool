import AppKit
import AstroCore
import SwiftUI

// MARK: - Row-scoped sheet identity

/// One target+session-date pair, `Identifiable` so a `@State` of this type
/// can drive a `.sheet(item:)` -- the "only one row's sheet-triggering button
/// can be open at a time" pattern shared by `CalibLinkSheet`/`StackListSheet`
/// call sites across `AllTargetsPage` and `TargetDetailPage`/`SessionsSegment`.
struct LinkingSession: Identifiable {
    let target: String
    let date: String
    var id: String { "\(target):\(date)" }
}

/// One target, `Identifiable` so a `@State` of this type can drive a
/// `.sheet(item:)` -- same row-scoped pattern as `LinkingSession`, for
/// sheets that only need the target (`PlateSolveSheet`).
struct SolvingTarget: Identifiable {
    let target: String
    var id: String { target }
}

// MARK: - Shared formatting

/// Small formatting helpers shared by every `TargetDetail/*.swift` segment
/// (and reused across the whole app) -- kept as static functions on a
/// non-instantiable enum rather than free functions so call sites read as
/// `TDFormat.hm(...)` instead of colliding with each file's own local
/// `formatDuration`/`format...` helpers.
///
/// R10 review: this app's no-value glyph is CONTEXT-dependent, not one
/// symbol everywhere -- table CELLS use "-" (a missing metric among many
/// filled ones in a dense grid), TILES use "n/a" (a single missing summary
/// value, where "-" reads as a dash/minus rather than "no data"). R11-T1
/// centralized both glyphs here (`missingCell`/`missingTile`) plus a
/// convenience wrapper each (`cell(_:)`/`tile(_:)`) so a call site reads its
/// fallback off ONE source of truth instead of its own repeated
/// `?? "-"`/`?? "n/a"` literal -- a third, undocumented glyph ("—" em dash)
/// had crept into the "Saját döntés" column's no-verdict state; that's now
/// `missingCell` too, since it's a table cell like any other. Which of the
/// two glyphs a given call site reaches for is still its own choice (there's
/// no single `TDFormat.missing` merging them) -- this comment just states
/// the rule so the two don't drift into each other again.
/// Duration formatting: `hm` (h:mm, e.g. "10:00") is the CANONICAL format
/// across this app -- a bare decimal-hours suffix ("3.2 ó") only appears
/// where no total-seconds value exists to feed `hm` with (e.g.
/// `DiscoveryPage`'s "Látható" column, sourced from `DiscoveryRow`, which
/// only ever carries an already-rounded hour count, never raw seconds).
enum TDFormat {
    /// Table-cell missing-value glyph -- see this enum's own doc comment.
    static let missingCell = "-"
    /// Tile (single summary value) missing-value glyph -- see this enum's
    /// own doc comment.
    static let missingTile = "n/a"

    /// `value ?? missingCell`, spelled out once so table cells share a
    /// single call instead of each repeating its own `?? "-"` literal.
    static func cell(_ value: String?) -> String { value ?? missingCell }

    /// `value ?? missingTile` -- same idea as `cell(_:)`, for a `StatTile`'s
    /// `value`/`caption` text.
    static func tile(_ value: String?) -> String { value ?? missingTile }

    static func hm(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    static func bytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// `"05h 34m 32.0s"` -- right ascension in hours/minutes/seconds,
    /// normalized to `[0, 360)` degrees before the /15 hour conversion. Same
    /// formula `TargetReport.raHMS` uses (that one is `private` to
    /// `AstroCore/Export/TargetReport.swift`).
    static func raHMS(_ deg: Double) -> String {
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
    static func decDMS(_ deg: Double) -> String {
        let sign = deg < 0 ? "-" : "+"
        let absDeg = abs(deg)
        let d = Int(absDeg)
        let minutesFull = (absDeg - Double(d)) * 60
        let m = Int(minutesFull)
        let s = (minutesFull - Double(m)) * 60
        return "\(sign)\(String(format: "%02d° %02d' %04.1f\"", d, m, s))"
    }

    /// Parses the exact `"yyyy-MM-dd'T'HH:mm:ss'Z'"` shape
    /// `SessionTimeline.timeline`'s own `windowStart`/`windowEnd`/gap
    /// timestamps are formatted in -- app-layer copy of `NightReport`'s
    /// `private static let isoZFormatter` (that one isn't reachable from
    /// this module).
    static let isoZFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    /// `"14:32"` from a `"yyyy-MM-ddTHH:mm:ssZ"` string -- a plain substring
    /// slice, same convention as `NightReport.shortTime`.
    static func shortTime(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso }
        let start = iso.index(iso.startIndex, offsetBy: 11)
        let end = iso.index(iso.startIndex, offsetBy: 16)
        return String(iso[start..<end])
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// `"8,2h"` -- decimal hours with the Hungarian comma separator (one
    /// decimal place), for compact per-filter breakdown text ("Ha 8,2h ·
    /// OIII 3,1h") where the canonical `hm` (h:mm) format would run too wide
    /// across several filters side by side. Same "swap the ASCII decimal
    /// point for a comma" trick `ExposureAdvisor`'s own private `hu` helper
    /// (AstroCore) established first, for the same reason (Hungarian UI
    /// text, not locale-dependent formatting).
    static func decimalHours(_ seconds: Double) -> String {
        let hours = seconds / 3600.0
        return "\(String(format: "%.1f", hours).replacingOccurrences(of: ".", with: ","))h"
    }

    /// `"Ha 8,2h · OIII 3,1h"` -- the top `maxCount` filters from `breakdown`
    /// (already sorted seconds-descending by `FilterBreakdownQueries.
    /// breakdown`), for `TargetDetailPage`'s "Valós integráció" tile caption
    /// and `NightsPage`'s "Szűrők" column. `nil` when `breakdown` has no
    /// REAL filter at all (empty, or only
    /// `FilterBreakdownQueries.noFilterSentinel`) -- callers fall back to
    /// their own filterless-caption text in that case (R11-T5/F1: "csak-
    /// szűrőtlen anyagnál maradjon a mostani caption").
    static func filterBreakdownSummary(_ breakdown: [FilterIntegration], maxCount: Int = 3) -> String? {
        let real = breakdown.filter { $0.filter != FilterBreakdownQueries.noFilterSentinel }
        guard !real.isEmpty else { return nil }
        return real.prefix(maxCount).map { "\($0.filter) \(decimalHours($0.integrationSeconds))" }.joined(separator: " · ")
    }
}

/// szerkesztett=kék, starless=lila, starmask=szürke, export=zöld (R8-3
/// spec); `.original` gets a neutral gray -- it's the expected kind for a
/// group's own `base` row and isn't otherwise called out. Shared by
/// `AllTargetsPage`'s (former) `StackGroupSheet` and the new `StacksSegment`.
func stackKindColor(_ kind: StackVariantKind) -> Color {
    switch kind {
    case .original: return .gray
    case .edited: return .blue
    case .starless: return .purple
    case .starmask: return .gray.opacity(0.7)
    case .export_: return .green
    }
}

// MARK: - Calibration hard-linking sheet

/// Confirmation sheet for the one new write operation this tool performs
/// against the user's existing library: hard-linking matching calibration
/// masters (`calibration_library/darks|flats|biases`) into this session's own
/// `darks`/`biases` folders. Loads `AppState.calibLinkPlan` on appear, shows
/// it grouped by destination with each item's reason, and only ever writes
/// when the user explicitly presses "Linkelés" -- never on open, never
/// automatically. Shared by `AllTargetsPage`'s session-row context menu and
/// `TargetDetailPage`'s Áttekintés/Sessionök segments (R9-T3).
struct CalibLinkSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kalibráció linkelése").font(.headline)
            Text("\(target) / \(date)").foregroundStyle(.secondary)

            if let result = appState.calibLinkResult {
                resultView(result)
            } else if let plan = appState.calibLinkPlan {
                planView(plan)
            } else {
                ProgressView().controlSize(.small)
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 220)
        .onAppear {
            appState.loadCalibLinkPlan(target: target, date: date)
        }
        .onDisappear {
            appState.clearCalibLinkPlan()
        }
    }

    @ViewBuilder
    private func planView(_ plan: CalibLinkPlan) -> some View {
        if plan.items.isEmpty {
            if !plan.mismatchReasons.isEmpty {
                Text("Nem linkelhető: \(plan.mismatchReasons.joined(separator: ", "))")
                    .foregroundStyle(.orange)
            } else {
                Text("Nincs linkelhető kalibráció ehhez a session-höz.")
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groupedDestDirs(plan), id: \.self) { destDir in
                        Text(destDir).font(.subheadline).bold()
                        ForEach(plan.items.filter { $0.destDir == destDir }, id: \.sourcePath) { item in
                            Text("•  \(item.sourcePath)  —  \(item.reason)")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }

        HStack {
            Spacer()
            if appState.isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Mégse") { dismiss() }
            Button("Linkelés") { appState.applyCalibLinkPlan() }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.items.isEmpty || appState.isBusy)
                .help(plan.items.isEmpty ? "Nincs linkelhető kalibráció" : "")
        }
    }

    private func resultView(_ result: LinkResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Linkelve: \(result.linked.count), kihagyva: \(result.skipped.count)")
                .font(.callout)
            if !result.skipped.isEmpty {
                Text("Kihagyva (már létezett a célban): \(result.skipped.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func groupedDestDirs(_ plan: CalibLinkPlan) -> [String] {
        Set(plan.items.map(\.destDir)).sorted()
    }
}

// MARK: - Plate-solve sheet (R7-1)

/// Runs `AppState.runPlateSolve(target:)` on appear and shows the resulting
/// `SolveSummary` -- same "progress until `AppState` sets a result" pattern
/// as `CalibLinkSheet`, just with no plan/confirm step (the operation always
/// runs immediately; there's nothing to review beforehand since Siril work
/// never touches the library). Shared by `AllTargetsPage` and `TargetDetailPage`'s
/// Áttekintés segment (R9-T3).
struct PlateSolveSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Plate-solve").font(.headline)
            Text(target).foregroundStyle(.secondary)

            if let summary = appState.plateSolveSummary {
                resultView(summary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 160)
        .onAppear {
            appState.runPlateSolve(target: target)
        }
        .onDisappear {
            appState.plateSolveSummary = nil
        }
    }

    private func resultView(_ summary: SolveSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Megoldva: \(summary.solved) / \(summary.attempted) (sikertelen: \(summary.failed), kihagyva: \(summary.skipped))")
                .font(.callout)
            HStack {
                Spacer()
                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Stack-list export (R7-B4)

/// "Stackelés előkészítése…" sheet (A.10 rename from "Stack-lista…"): a
/// keep-fraction slider (50-100%) drives a live `StackList.select` preview
/// (criteria + selected/total counts), and "Exportálás" runs
/// `StackList.export` -- the additive hard-link + `.dssfilelist`/`.ssf` write
/// this whole feature bridges frame scoring to actual stacking with. Same
/// "load on appear, clear on disappear" pattern as `CalibLinkSheet`/
/// `PlateSolveSheet`; unlike `CalibLinkSheet` there's no separate `--dry-run`
/// state -- adjusting the slider just recomputes the (read-only) preview in
/// place. Shared by `AllTargetsPage` and `TargetDetailPage`'s Sessionök/Stackek
/// segments (R9-T3).
///
/// R11-T11 (F15): when the live preview's `selection.perFilter` is non-`nil`
/// (more than one filter bucket in this session), the preview also shows a
/// per-filter "Ha 45/52 · OIII 28/40" breakdown line and a "Szűrőnkénti
/// finomhangolás" `DisclosureGroup` with one 50-100% slider per filter
/// (`perFilterFractions`, keyed by filter name); moving the COMMON slider
/// resets every per-filter override back to following it. A filter-less or
/// single-filter session's sheet looks exactly like it did before this
/// ticket -- no per-filter UI at all.
struct StackListSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String

    @State private var keepFraction: Double = 0.8
    /// Per-filter keepFraction overrides, keyed by the same filter name
    /// `StackFilterSelection.filter` uses -- empty means "every filter
    /// follows the common `keepFraction` slider". Reset to empty whenever
    /// the common slider itself moves (R11-T11 spec: "a közös csúszka
    /// mozgatása visszaállítja a szűrőnkéntieket").
    @State private var perFilterFractions: [String: Double] = [:]
    @State private var perFilterTuningExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stackelés előkészítése").font(.headline)
            Text("\(target) / \(date)").foregroundStyle(.secondary)

            HStack {
                Text("Megtartás:")
                Slider(value: $keepFraction, in: 0.5...1.0, step: 0.05)
                Text("\(Int((keepFraction * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(appState.stackListExportDir != nil)
            .onChange(of: keepFraction) { _, newValue in
                perFilterFractions = [:]
                reload(keepFraction: newValue)
            }

            if let exportDir = appState.stackListExportDir {
                resultView(exportDir)
            } else if let selection = appState.stackListSelection {
                selectionView(selection)
            } else {
                ProgressView().controlSize(.small)
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
        .onAppear {
            reload(keepFraction: keepFraction)
        }
        .onDisappear {
            appState.clearStackListSelection()
        }
    }

    private func reload(keepFraction: Double) {
        appState.loadStackListSelection(
            target: target, date: date, keepFraction: keepFraction, keepFractionPerFilter: perFilterFractions
        )
    }

    @ViewBuilder
    private func selectionView(_ selection: StackSelection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kiválasztva: \(selection.selectedFrames) / \(selection.totalFrames)").font(.callout)
            if let perFilter = selection.perFilter, !perFilter.isEmpty {
                Text(perFilterSummary(perFilter)).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(selection.criteria, id: \.self) { line in
                        Text("•  \(line)").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)

            if let perFilter = selection.perFilter, !perFilter.isEmpty {
                perFilterTuningView(perFilter)
            }

            Text(exportDestinationCaption(selection))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        HStack {
            Spacer()
            if appState.isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Mégse") { dismiss() }
            Button("Exportálás") { appState.exportStackList() }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.selectedFrames == 0 || appState.isBusy)
                .help(selection.selectedFrames == 0 ? "Nincs kiválasztható keret" : "")
        }
    }

    private func perFilterSummary(_ perFilter: [StackFilterSelection]) -> String {
        perFilter.map { "\($0.filter) \($0.selectedFrames)/\($0.totalFrames)" }.joined(separator: " · ")
    }

    @ViewBuilder
    private func perFilterTuningView(_ perFilter: [StackFilterSelection]) -> some View {
        DisclosureGroup("Szűrőnkénti finomhangolás", isExpanded: $perFilterTuningExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(perFilter, id: \.filter) { entry in
                    let binding = Binding<Double>(
                        get: { perFilterFractions[entry.filter] ?? keepFraction },
                        set: { newValue in
                            perFilterFractions[entry.filter] = newValue
                            reload(keepFraction: keepFraction)
                        }
                    )
                    HStack {
                        Text(entry.filter)
                            .font(.caption)
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                        Slider(value: binding, in: 0.5...1.0, step: 0.05)
                        Text("\(Int((binding.wrappedValue * 100).rounded()))%")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
        .disabled(appState.stackListExportDir != nil)
    }

    /// R12-U2 (point 5): the REAL, `Sanitizer`-slugged export path
    /// (`StackList.slug`) -- a raw `"\(target)-\(date)"` literal used to
    /// silently diverge from the actual on-disk folder name whenever
    /// `target` contains a character `Sanitizer` strips (e.g. a `/` in a
    /// catalog-style target name). Also names the `.ssf` explicitly now,
    /// not just the `.dssfilelist` -- both artifacts matter equally to
    /// "how do I actually stack this".
    private func exportDestinationCaption(_ selection: StackSelection) -> String {
        let base = ".astro_tool/stacklists/\(StackList.slug(target: target, date: date))/"
        if selection.perFilter != nil {
            return "\(base) — lights/<szűrő>/ hardlinkek + .ssf/.dssfilelist szűrőnként + manifest.csv"
        } else {
            return "\(base) — lights/ hardlinkek + .ssf/.dssfilelist + manifest.csv"
        }
    }

    private func resultView(_ dir: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exportálva: \(dir.lastPathComponent)").font(.callout)
            Text(dir.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            // R12-U2 (point 2): only shown when the re-export sync actually
            // removed something -- a fresh export or an unchanged re-export
            // says nothing extra here.
            if appState.stackListRemovedStaleCount > 0 {
                Text("\(appState.stackListRemovedStaleCount) elavult link eltávolítva")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
