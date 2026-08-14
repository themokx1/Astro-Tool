import AppKit
import AstroApplication
import AstroCore
import SwiftUI

/// One dark-coverage combo (`CalibNeed`), wrapped only to give the `Table`
/// an `Identifiable` row -- no field is recomputed, `need` is the engine's
/// own value untouched.
private struct CalibrationCoverageRow: Identifiable {
    let id: String
    let need: CalibNeed

    init(_ need: CalibNeed) {
        self.need = need
        let tempLabel: String = need.tempC.map { String($0) } ?? "nil"
        self.id = "\(need.kind.rawValue)|\(need.exposureSeconds)|\(tempLabel)"
    }
}

public struct CalibrationView: View {
    let rootURL: URL?
    let accessMode: LibraryAccessMode
    let chooseLibrary: () -> Void
    @State private var store = CalibrationStore()
    @State private var selectedCoverageID: String?
    @State private var selectedMasterID: String?
    @State private var showsLinkPreview = false

    public init(rootURL: URL?, accessMode: LibraryAccessMode = .readOnly, chooseLibrary: @escaping () -> Void) {
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.chooseLibrary = chooseLibrary
    }

    private var coverageRows: [CalibrationCoverageRow] {
        store.coverage.map(CalibrationCoverageRow.init)
    }

    public var body: some View {
        WorkspacePage(
            eyebrow: "Read-only inventory · explicit linking",
            title: "Calibration",
            subtitle: "Master-dark inventory and per-session linking, applied only through WriteGuard."
        ) {
            if let rootURL {
                if store.isLoading {
                    ProgressView("Reading calibration coverage…").frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    workspace(rootURL: rootURL)
                }
            } else {
                ContentUnavailableView {
                    Label("No library open", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text(store.errorMessage ?? "Choose an image library to review calibration coverage.")
                } actions: {
                    Button("Choose Image Library…", action: chooseLibrary).buttonStyle(.borderedProminent)
                }
                .frame(minHeight: 300)
            }
        }
        .task(id: rootURL) {
            if let rootURL { await store.load(rootURL: rootURL, accessMode: accessMode) }
        }
        .navigationTitle("Calibration")
        .accessibilityLabel("Calibration")
        .accessibilityIdentifier("v2.detail.library.calibration")
        .sheet(isPresented: $showsLinkPreview) {
            linkPreviewSheet
        }
    }

    @ViewBuilder
    private func workspace(rootURL: URL) -> some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            MetricCard(
                title: "Coverage gaps", value: "\(store.coverage.filter { $0.matchedMasterPath == nil }.count)",
                detail: "Combos without a master", systemImage: "exclamationmark.triangle"
            )
            MetricCard(
                title: "Master darks", value: "\(store.masters.count)",
                detail: "Inventoried directories", systemImage: "archivebox"
            )
            MetricCard(
                title: "Access", value: store.accessMode == .mutationEnabled ? "Writable" : "Read only",
                detail: "Images protected", systemImage: "lock.shield"
            )
        }
        GroupBox("Session coverage") {
            Table(coverageRows, selection: $selectedCoverageID) {
                TableColumn("Combo") { row in
                    Text("\(formattedNumber(row.need.exposureSeconds)) s / \(row.need.tempC.map { formattedNumber($0) + " °C" } ?? "—")")
                        .font(.callout.monospaced())
                }
                TableColumn("Lights") { row in Text("\(row.need.lightCount)") }
                    .width(min: 60, ideal: 70)
                TableColumn("Master") { row in
                    Text(row.need.matchedMasterPath ?? "Missing")
                        .foregroundStyle(row.need.matchedMasterPath == nil ? AstroTokens.Color.spectralBlue : .primary)
                }
                TableColumn("Sessions") { row in
                    Text(row.need.sessions.map { "\($0.target) · \($0.date)" }.joined(separator: ", "))
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 180)
            .contextMenu(forSelectionType: String.self) { ids in
                if let row = coverageRows.first(where: { ids.contains($0.id) }) {
                    coverageActionMenu(row)
                }
            }
            .accessibilityIdentifier("v2.calibration.coverage-table")
        }
        GroupBox("Master darks") {
            Table(store.masters, selection: $selectedMasterID) {
                TableColumn("Path") { master in
                    Text(master.path).font(.callout.monospaced()).lineLimit(1)
                }
                TableColumn("Temp °C") { master in
                    Text(master.temperatureCelsius.map { formattedNumber($0) } ?? "—")
                }
                .width(min: 70, ideal: 90)
                TableColumn("Age (days)") { master in
                    Text(master.ageDays.map(String.init) ?? "—")
                }
                .width(min: 90, ideal: 110)
                TableColumn("Status") { master in masterStatus(master) }
                    .width(min: 140, ideal: 180)
            }
            .frame(minHeight: 180)
            .contextMenu(forSelectionType: CalibrationMasterInfo.ID.self) { ids in
                if let master = store.masters.first(where: { ids.contains($0.id) }) {
                    masterActionMenu(master, rootURL: rootURL)
                }
            }
            .accessibilityIdentifier("v2.calibration.masters-table")
        }
    }

    @ViewBuilder
    private func coverageActionMenu(_ row: CalibrationCoverageRow) -> some View {
        Button("Preview Link…") { preparePreview(for: row) }
            .disabled(row.need.sessions.isEmpty)
            .help("Preview which sessions would link to a matching master dark")
    }

    @ViewBuilder
    private func masterActionMenu(_ master: CalibrationMasterInfo, rootURL: URL) -> some View {
        Button("Show in Finder") { revealMaster(master, rootURL: rootURL) }
            .disabled(masterURL(for: master, rootURL: rootURL) == nil)
    }

    private func masterStatus(_ master: CalibrationMasterInfo) -> some View {
        HStack(spacing: AstroTokens.Spacing.compact) {
            if master.isStale {
                Label("Stale", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
            }
            if master.isUnused {
                Label("Unused", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
            if !master.isStale, !master.isUnused {
                Label("OK", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        }
        .font(.caption)
    }

    private func preparePreview(for row: CalibrationCoverageRow) {
        guard let session = row.need.sessions.first else { return }
        Task {
            await store.preparePlan(target: session.target, date: session.date)
            showsLinkPreview = true
        }
    }

    @ViewBuilder
    private var linkPreviewSheet: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            HStack {
                Text("Link Preview").font(.title3.bold())
                Spacer()
                Button("Close") {
                    showsLinkPreview = false
                    store.clearPlan()
                }.keyboardShortcut(.cancelAction)
            }
            if store.isPlanning {
                ProgressView("Building plan…")
            } else if let plan = store.linkPlan {
                Text("\(plan.target) · \(plan.date)").font(.headline)
                if plan.items.isEmpty {
                    Text(plan.mismatchReasons.isEmpty
                        ? "Nothing to link -- this session already has what it needs."
                        : plan.mismatchReasons.joined(separator: "; "))
                        .foregroundStyle(.secondary)
                } else {
                    List(plan.items, id: \.destDir) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.sourcePath).font(.callout.monospaced())
                            Text("→ \(item.destDir) · \(item.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 160)
                }
                if let receipt = store.lastReceipt {
                    Label("Linked \(receipt.linked.count) file(s), skipped \(receipt.skipped.count)", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
                if let planErrorMessage = store.planErrorMessage {
                    Text(planErrorMessage).foregroundStyle(.orange)
                }
                if store.accessMode != .mutationEnabled {
                    Label("Requires write access. Enable write operations in Settings to apply this link.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Apply Link") { Task { await store.applyPlan() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.accessMode != .mutationEnabled || plan.items.isEmpty)
                        .help("Link the matched master calibration files into this session")
                }
            } else if let planErrorMessage = store.planErrorMessage {
                Text(planErrorMessage).foregroundStyle(.orange)
            }
        }
        .padding(AstroTokens.Spacing.section)
        .frame(minWidth: 480, minHeight: 360)
        .accessibilityIdentifier("v2.calibration.link-preview")
    }

    private func masterURL(for master: CalibrationMasterInfo, rootURL: URL) -> URL? {
        let canonicalRoot = rootURL.standardizedFileURL
        let candidate = canonicalRoot.appendingPathComponent(master.path).standardizedFileURL
        let allowedPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(allowedPrefix),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func revealMaster(_ master: CalibrationMasterInfo, rootURL: URL) {
        guard let url = masterURL(for: master, rootURL: rootURL) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func formattedNumber(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
