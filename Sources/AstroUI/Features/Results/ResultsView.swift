import AstroApplication
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
private final class ResultsStore {
    var snapshot: ResultsSnapshot?
    var isLoading = false
    var errorMessage: String?
    /// This project's own library/folder key and most recent night, loaded
    /// alongside `snapshot` -- everything the "Export Stack List" menu item
    /// needs to call `ExportService.stackList(target:date:)`, without the
    /// export menu having to know how to resolve either on its own.
    var canonicalFolderName: String?
    var latestNightDate: String?

    func load(rootURL: URL, projectID: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let metadata = try ProjectsStore.productionMetadata(rootURL: rootURL)
            snapshot = try await ResultsQuery(metadata: metadata).snapshot(projectID: projectID)
            if let projectSnapshot = try await ProjectsQuery(metadata: metadata).project(id: projectID) {
                canonicalFolderName = projectSnapshot.canonicalFolderName
                latestNightDate = projectSnapshot.nights.first?.night.localDate
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

public struct ResultsView: View {
    let rootURL: URL
    let project: ProjectRecord
    let dismiss: () -> Void
    @State private var store = ResultsStore()
    @State private var selectedResultID: UUID?

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.isLoading {
                ProgressView("Reading result lineage…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.errorMessage {
                ContentUnavailableView("Results unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let snapshot = store.snapshot, !snapshot.results.isEmpty {
                HSplitView {
                    resultTable(snapshot).frame(minWidth: 440, idealWidth: 560)
                    resultDetail(snapshot).frame(minWidth: 430)
                }
            } else {
                ContentUnavailableView {
                    Label("No results recorded", systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text("Prepared stacks and processed variants will appear here with their sources and software provenance.")
                }
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(.background)
        .task { await store.load(rootURL: rootURL, projectID: project.id) }
        .accessibilityIdentifier("v2.results.workspace")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Results").font(.title2.bold())
                Text("\(project.displayName) · stacks, variants, and provenance").foregroundStyle(.secondary)
            }
            Spacer()
            ExportMenu(items: stackListExportItems, accessibilityID: "v2.results.export")
            if let snapshot = store.snapshot,
               let result = selectedResult(in: snapshot) {
                resultActions(result)
            }
            Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
        }.padding(20)
    }

    /// The project's latest-night stack list (`AppState.exportStackList`'s
    /// V2 equivalent) -- `[]` until `store.load` has resolved this project's
    /// own library/folder key and most recent night.
    private var stackListExportItems: [ExportMenuItem] {
        guard let target = store.canonicalFolderName, let date = store.latestNightDate else { return [] }
        return [
            .file(title: "Stack List…", systemImage: "square.stack.3d.up", contentType: .commaSeparatedText) {
                let export = try ExportService.production(rootURL: rootURL).stackList(target: target, date: date)
                return (export.content, export.suggestedFilename, [])
            },
        ]
    }

    private func resultTable(_ snapshot: ResultsSnapshot) -> some View {
        Table(snapshot.results, selection: $selectedResultID) {
            TableColumn("Preview") { result in
                if let relativePath = result.relativePath {
                    FrameThumbnailCell(rootURL: rootURL, relativePath: relativePath)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .opacity(0.35)
                        .frame(width: 28, height: 28)
                }
            }
            .width(min: 36, ideal: 36, max: 36)
            TableColumn("Result") { result in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Label(result.role.rawValue.capitalized, systemImage: result.role == .final ? "checkmark.seal.fill" : "square.stack")
                            .font(.headline)
                        if snapshot.publishableResultID == result.id {
                            Text("Publishable").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green.opacity(0.18), in: Capsule())
                                .accessibilityIdentifier("v2.results.publishable")
                        }
                    }
                    Text(result.relativePath ?? "Path not recorded")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 4)
            }
            TableColumn("Created") { result in
                Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 125, ideal: 145)
            TableColumn("Software") { result in
                Text(softwareLabel(result)).lineLimit(1)
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: UUID.self) { resultIDs in
            if let result = snapshot.results.first(where: { resultIDs.contains($0.id) }) {
                resultActionMenu(result)
            }
        } primaryAction: { resultIDs in
            if let result = snapshot.results.first(where: { resultIDs.contains($0.id) }) {
                openResult(result)
            }
        }
        .background(QuickLookSpacebarMonitor(
            isEnabled: { selectedResultID != nil },
            onSpace: {
                if let result = selectedResult(in: snapshot) {
                    quickLook(result)
                }
            }
        ))
        .accessibilityIdentifier("v2.results.table")
        .onAppear {
            selectedResultID = selectedResultID ?? snapshot.publishableResultID ?? snapshot.results.last?.id
        }
    }

    private func resultActions(_ result: ResultLineageSnapshot) -> some View {
        HStack(spacing: 8) {
            Button("Open Result") { openResult(result) }
                .disabled(resultURL(for: result) == nil)
            Menu {
                resultActionMenu(result)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func resultActionMenu(_ result: ResultLineageSnapshot) -> some View {
        Button("Open Result") { openResult(result) }
            .disabled(resultURL(for: result) == nil)
        Button("Show in Finder") { revealResult(result) }
            .disabled(resultURL(for: result) == nil)
        Button("Quick Look") { quickLook(result) }
            .disabled(resultURL(for: result) == nil)
        Divider()
        Button("Copy Path") { copyPath(result) }
            .disabled(result.relativePath == nil)
    }

    private func selectedResult(in snapshot: ResultsSnapshot) -> ResultLineageSnapshot? {
        snapshot.results.first { $0.id == selectedResultID }
    }

    private func softwareLabel(_ result: ResultLineageSnapshot) -> String {
        [result.softwareName, result.softwareVersion]
            .compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Unknown"
    }

    private func resultURL(for result: ResultLineageSnapshot) -> URL? {
        guard let relativePath = result.relativePath else { return nil }
        let canonicalRoot = rootURL.standardizedFileURL
        let candidate = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        let allowedPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(allowedPrefix),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func openResult(_ result: ResultLineageSnapshot) {
        guard let url = resultURL(for: result) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealResult(_ result: ResultLineageSnapshot) {
        guard let url = resultURL(for: result) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func quickLook(_ result: ResultLineageSnapshot) {
        guard let url = resultURL(for: result) else { return }
        QuickLookPreviewController.shared.preview(url)
    }

    private func copyPath(_ result: ResultLineageSnapshot) {
        guard let relativePath = result.relativePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relativePath, forType: .string)
    }

    @ViewBuilder private func resultDetail(_ snapshot: ResultsSnapshot) -> some View {
        if let result = snapshot.results.first(where: { $0.id == selectedResultID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(result.role.rawValue.capitalized).font(.largeTitle.bold())
                    HStack(spacing: 12) {
                        metric("Kind", result.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        metric("Created", result.createdAt.formatted(date: .abbreviated, time: .shortened))
                        metric("Software", [result.softwareName, result.softwareVersion].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "Unknown")
                    }
                    GroupBox("Lineage") {
                        VStack(alignment: .leading, spacing: 10) {
                            lineageRow("Input series", count: result.inputSeriesIDs.count, icon: "camera.aperture")
                            lineageRow("Input frames", count: result.sourceFrameIDs.count, icon: "photo.stack")
                            lineageRow("Source result", count: result.sourceResultIDs.count, icon: "arrow.triangle.branch")
                            lineageRow("Calibration assets", count: result.calibrationAssets.count, icon: "circle.lefthalf.filled")
                            if let parent = result.parentResultID {
                                Text("Parent · \(parent.uuidString)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.accessibilityIdentifier("v2.results.lineage")
                    GroupBox("File") {
                        Text(result.relativePath ?? "No path recorded")
                            .font(.callout.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    Spacer()
                }.padding(24)
            }
        } else {
            ContentUnavailableView("Select a result", systemImage: "square.stack.3d.up")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func lineageRow(_ title: String, count: Int, icon: String) -> some View {
        HStack { Label(title, systemImage: icon); Spacer(); Text("\(count)").foregroundStyle(.secondary) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
