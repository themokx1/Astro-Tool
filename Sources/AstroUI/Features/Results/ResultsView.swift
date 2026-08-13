import AstroApplication
import SwiftUI

@MainActor
@Observable
private final class ResultsStore {
    var snapshot: ResultsSnapshot?
    var isLoading = false
    var errorMessage: String?

    func load(rootURL: URL, projectID: UUID) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let metadata = try ProjectsStore.productionMetadata(rootURL: rootURL)
            snapshot = try await ResultsQuery(metadata: metadata).snapshot(projectID: projectID)
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
                    resultList(snapshot).frame(minWidth: 260, idealWidth: 310)
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
            Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
        }.padding(20)
    }

    private func resultList(_ snapshot: ResultsSnapshot) -> some View {
        List(snapshot.results, selection: $selectedResultID) { result in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(result.role.rawValue.capitalized, systemImage: result.role == .final ? "checkmark.seal.fill" : "square.stack")
                    if snapshot.publishableResultID == result.id {
                        Text("Publishable").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.18), in: Capsule())
                            .accessibilityIdentifier("v2.results.publishable")
                    }
                }.font(.headline)
                Text(result.relativePath ?? "Path not recorded").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(.vertical, 6).tag(result.id)
        }
        .navigationTitle("Result history")
        .onAppear { selectedResultID = selectedResultID ?? snapshot.publishableResultID ?? snapshot.results.last?.id }
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
