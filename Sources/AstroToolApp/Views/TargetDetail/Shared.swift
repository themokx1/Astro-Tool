import AppKit
import AstroCore
import SwiftUI

// MARK: - Row-scoped sheet identity

/// One target+session-date pair, `Identifiable` so a `@State` of this type
/// can drive a `.sheet(item:)` -- the "only one row's sheet-triggering button
/// can be open at a time" pattern shared by `CalibLinkSheet`/`StackListSheet`
/// call sites across `StatsView` and `TargetDetailPage`/`SessionsSegment`.
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
/// (and reused from `StatsView`) -- kept as static functions on a
/// non-instantiable enum rather than free functions so call sites read as
/// `TDFormat.hm(...)` instead of colliding with each file's own local
/// `formatDuration`/`format...` helpers.
enum TDFormat {
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
}

/// szerkesztett=kék, starless=lila, starmask=szürke, export=zöld (R8-3
/// spec); `.original` gets a neutral gray -- it's the expected kind for a
/// group's own `base` row and isn't otherwise called out. Shared by
/// `StatsView`'s (former) `StackGroupSheet` and the new `StacksSegment`.
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
/// automatically. Shared by `StatsView`'s session-row context menu and
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
/// never touches the library). Shared by `StatsView` and `TargetDetailPage`'s
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
/// place. Shared by `StatsView` and `TargetDetailPage`'s Sessionök/Stackek
/// segments (R9-T3).
struct StackListSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String

    @State private var keepFraction: Double = 0.8

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
                appState.loadStackListSelection(target: target, date: date, keepFraction: newValue)
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
            appState.loadStackListSelection(target: target, date: date, keepFraction: keepFraction)
        }
        .onDisappear {
            appState.clearStackListSelection()
        }
    }

    @ViewBuilder
    private func selectionView(_ selection: StackSelection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kiválasztva: \(selection.selectedFrames) / \(selection.totalFrames)").font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(selection.criteria, id: \.self) { line in
                        Text("•  \(line)").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
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

    private func resultView(_ dir: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exportálva: \(dir.lastPathComponent)").font(.callout)
            Text(dir.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
