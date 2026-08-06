import AppKit
import AstroCore
import SwiftUI

/// One row of the embedded stack `Table`: either a stack-group roll-up
/// (`base` + best-known exposure) or one of its variant files nested under
/// it -- same `children`-keypath `Table` pattern `StatsRow` uses for the
/// main stats table. Moved here (R9-T3/A.3) from `StatsView`'s old
/// `StackGroupSheet`, which this segment replaces: the spec calls for the
/// same hierarchical table EMBEDDED in the page rather than behind a sheet.
private struct StackGroupRow: Identifiable {
    enum Kind {
        case group(StackGroup)
        /// The variant file, plus its parent group's `stem` -- carried along
        /// so `markerHighlightedName(for:stem:)` doesn't need to re-derive it
        /// (`StackDiscovery.stem(for:)` is internal to `AstroCore`, not
        /// reachable from this app-layer view at all).
        case variant(StackFile, stem: String)
    }

    let id: String
    let kind: Kind
    var children: [StackGroupRow]?
}

/// R9-T3/A.3's "Stackek" segment: every discovered stack for the target,
/// grouped into variant families (`StackDiscovery.groupedStacks`) instead of
/// dumping dozens of flat, unrelated-looking rows. A group's row shows the
/// edited-vs-original classification, the best-known exposure (name-parsed,
/// falling back to the FITS header), and Finder/open actions; its variants
/// nest underneath with the same actions plus a colored kind badge. Formerly
/// `StatsView`'s `StackGroupSheet` (R8-3) -- moved and embedded per spec
/// rather than shown in a sheet; `StatsView`'s "Stackek…" row button is gone
/// (double-clicking the target row now opens this page instead).
struct StacksSegment: View {
    @Environment(AppState.self) private var appState
    let target: String

    /// The session currently shown in `StackListSheet`, `nil` when closed.
    /// `nil` date is impossible here (unlike a free-text picker) -- the
    /// toolbar button always resolves to a concrete session first (directly
    /// when there's only one, via a picker menu otherwise).
    @State private var stackListingSession: LinkingSession?

    private var groups: [StackGroup] { appState.stackGroupsByTarget[target] ?? [] }
    private var sessionDates: [String] { appState.stats.first { $0.target == target }?.sessionDates ?? [] }

    private var rows: [StackGroupRow] {
        groups.map { group in
            let children = group.variants.map { variant in
                StackGroupRow(id: "v:\(variant.path)", kind: .variant(variant, stem: group.stem), children: nil)
            }
            return StackGroupRow(id: "g:\(group.stem)", kind: .group(group), children: children.isEmpty ? nil : children)
        }
    }

    private var totalFileCount: Int {
        groups.reduce(0) { $0 + 1 + $1.variants.count }
    }

    /// "N stack-csoport · legjobb: 145×120 s (3:25) · összesen M fájl" -- the
    /// segment's summary header line. "Legjobb" is the first group's
    /// exposure since `groups` follows `stacks(target:...)`'s own
    /// best-integration-first sort.
    private var summaryLine: String {
        var line = "\(groups.count) stack-csoport"
        if let best = groups.first, let exposure = exposureText(best) {
            line += " · legjobb: \(exposure)"
        }
        line += " · összesen \(totalFileCount) fájl"
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summaryLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                stackPrepButton
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    "Nincs kész stack",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Nem találtunk stack-fájlt a `stacks/\(target)/`, a `processed/\(target)/` alatt, sem a session-mappákba mentve.")
                )
            } else {
                table
            }
        }
        .sheet(item: $stackListingSession) { session in
            StackListSheet(target: session.target, date: session.date)
        }
    }

    /// "Stackelés előkészítése…" (A.3 segment toolbar) -- opens a session
    /// picker when the target has more than one session (there's no single
    /// obvious "current" one to default to), otherwise goes straight to
    /// `StackListSheet` for the target's only session.
    @ViewBuilder
    private var stackPrepButton: some View {
        if sessionDates.count > 1 {
            Menu("Stackelés előkészítése…") {
                ForEach(sessionDates, id: \.self) { date in
                    Button(date) { stackListingSession = LinkingSession(target: target, date: date) }
                }
            }
        } else if let onlyDate = sessionDates.first {
            Button("Stackelés előkészítése…") {
                stackListingSession = LinkingSession(target: target, date: onlyDate)
            }
        }
    }

    private var table: some View {
        Table(rows, children: \.children) {
            TableColumn("Név") { row in nameCell(row) }
                .width(min: 220, ideal: 340)
            TableColumn("Típus") { row in typeCell(row) }
                .width(min: 80, ideal: 100)
            TableColumn("Expo") { row in exposureCell(row) }
                .width(min: 120, ideal: 170)
            TableColumn("Hely") { row in Text(locationLabel(for: path(of: row))) }
                .width(min: 70, ideal: 80)
            TableColumn("Méret") { row in Text(TDFormat.bytes(size(of: row))) }
                .width(min: 70, ideal: 90)
            TableColumn("Dátum") { row in Text(date(of: row) ?? "-") }
                .width(min: 90, ideal: 100)
            TableColumn("Műveletek") { row in actionsCell(row) }
                .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Column: Név

    @ViewBuilder
    private func nameCell(_ row: StackGroupRow) -> some View {
        switch row.kind {
        case .group(let group):
            Text(group.stem.replacingOccurrences(of: "_", with: " "))
                .lineLimit(1)
                .truncationMode(.middle)
                .help((group.base.path as NSString).lastPathComponent)
        case .variant(let file, let stem):
            markerHighlightedName(for: file, stem: stem)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)
        }
    }

    /// Highlights the part of a variant's filename beyond the shared `stem`
    /// (its parent group's `StackGroup.stem`) -- its own "edit chain"
    /// (`_work_graxpert_result_HOO_Improved`) or a `starless_`/`starmask_`
    /// prefix -- in orange, so the marker that makes THIS file different
    /// from the group's base is visible at a glance instead of buried inside
    /// a long flat filename.
    private func markerHighlightedName(for file: StackFile, stem: String) -> Text {
        let full = (file.path as NSString).lastPathComponent
        let ext = (full as NSString).pathExtension
        let nameNoExt = ext.isEmpty ? full : String(full.dropLast(ext.count + 1))

        var remaining = Substring(nameNoExt)
        var prefix = ""
        for marker in ["starless_", "starmask_"] where remaining.lowercased().hasPrefix(marker) {
            prefix = String(remaining.prefix(marker.count))
            remaining = remaining.dropFirst(marker.count)
            break
        }

        let coreLen = min(stem.count, remaining.count)
        let core = String(remaining.prefix(coreLen))
        let suffix = String(remaining.dropFirst(coreLen)) + (ext.isEmpty ? "" : ".\(ext)")

        var text = Text(prefix).foregroundColor(.secondary)
        text = text + Text(core)
        if !suffix.isEmpty { text = text + Text(suffix).foregroundColor(.orange) }
        return text
    }

    // MARK: - Column: Típus

    @ViewBuilder
    private func typeCell(_ row: StackGroupRow) -> some View {
        switch row.kind {
        case .group(let group): kindBadge(group.base.variantKind)
        case .variant(let file, _): kindBadge(file.variantKind)
        }
    }

    private func kindBadge(_ kind: StackVariantKind) -> some View {
        Text(kind.rawValue)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(Capsule().fill(stackKindColor(kind)))
    }

    // MARK: - Column: Expo

    @ViewBuilder
    private func exposureCell(_ row: StackGroupRow) -> some View {
        switch row.kind {
        case .group(let group):
            VStack(alignment: .leading, spacing: 1) {
                Text(exposureText(group) ?? "-").bold()
                if group.fromHeader {
                    Text("headerből").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .variant(let file, _):
            Text(variantExposureText(file) ?? "-").foregroundStyle(.secondary)
        }
    }

    /// "145×120 s · 3:25" -- a group's best-known exposure, from
    /// `framesBest`/`subSecondsBest`/`totalSecondsBest` (name-parsed or
    /// header-fallback, see `StackDiscovery.groupedStacks`). `nil` only when
    /// neither the name nor the header carried a frame count at all.
    private func exposureText(_ group: StackGroup) -> String? {
        guard let frames = group.framesBest else { return nil }
        let sub = group.subSecondsBest.map { String(format: "%.0f", $0) } ?? "?"
        var text = "\(frames)×\(sub) s"
        if let total = group.totalSecondsBest { text += " · \(TDFormat.hm(total))" }
        return text
    }

    private func variantExposureText(_ file: StackFile) -> String? {
        guard let frames = file.framesFromName else { return nil }
        let sub = file.subSecondsFromName.map { String(format: "%.0f", $0) } ?? "?"
        return "\(frames)×\(sub) s"
    }

    // MARK: - Column: Műveletek

    @ViewBuilder
    private func actionsCell(_ row: StackGroupRow) -> some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.open(url(of: row))
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Megnyitás")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url(of: row)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Finderben")
        }
    }

    // MARK: - Row field accessors

    private func path(of row: StackGroupRow) -> String {
        switch row.kind {
        case .group(let group): return group.base.path
        case .variant(let file, _): return file.path
        }
    }

    private func size(of row: StackGroupRow) -> Int64 {
        switch row.kind {
        case .group(let group): return group.base.sizeBytes
        case .variant(let file, _): return file.sizeBytes
        }
    }

    private func date(of row: StackGroupRow) -> String? {
        switch row.kind {
        case .group(let group): return group.base.sessionDate
        case .variant(let file, _): return file.sessionDate
        }
    }

    /// `config.rootPath` + the tracked relative path -- the on-disk location
    /// every `Open`/`Finderben` action operates on.
    private func url(of row: StackGroupRow) -> URL {
        URL(fileURLWithPath: appState.config.rootPath).appendingPathComponent(path(of: row))
    }

    /// Same top-level-path-component labeling the CLI's `locationLabel`
    /// uses -- kept as its own tiny copy here since the CLI target and this
    /// app target don't share a module.
    private func locationLabel(for path: String) -> String {
        let top = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        switch top {
        case "stacks": return "stacks"
        case "processed": return "processed"
        case "sessions": return "sessions"
        default: return "gyökér"
        }
    }
}
