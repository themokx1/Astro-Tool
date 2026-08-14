import AstroApplication
import SwiftUI

public struct LibraryView: View {
    let snapshot: LibrarySnapshot?
    let rootURL: URL?
    let chooseLibrary: () -> Void
    let convertSession: () -> Void
    let rescan: () -> Void

    public var body: some View {
        Group {
            if rootURL == nil {
                ContentUnavailableView {
                    Label("No library open", systemImage: "externaldrive")
                } description: {
                    Text("Choose a folder to build a local, read-only index. Your image files stay untouched.")
                } actions: {
                    Button("Choose Image Library…", action: chooseLibrary)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                WorkspacePage(eyebrow: "Local and private", title: "Library", subtitle: "A read-only index of the image folders already on your Mac.") {
                    HStack(spacing: AstroTokens.Spacing.standard) {
                        MetricCard(title: "Projects", value: snapshot.map { "\($0.projectCount)" } ?? "—", detail: "Canonical targets", systemImage: "folder")
                        MetricCard(title: "Nights", value: snapshot.map { "\($0.nightCount)" } ?? "—", detail: "Observed sessions", systemImage: "moon.stars")
                        MetricCard(title: "Frames", value: snapshot.map { "\($0.frameCount)" } ?? "—", detail: "No source writes", systemImage: "photo.stack")
                    }
                    GroupBox("Image library") {
                        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                            Label(rootURL?.lastPathComponent ?? "No library selected", systemImage: "externaldrive")
                                .font(.headline)
                            if let rootURL {
                                Text(rootURL.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                Label("Read-only access", systemImage: "lock.shield").foregroundStyle(.green)
                            }
                            HStack {
                                Button("Organize One Session…", action: convertSession)
                                    .buttonStyle(.borderedProminent)
                                Button("Rescan", systemImage: "arrow.clockwise", action: rescan)
                                    .buttonStyle(.bordered)
                                    .help("Re-read the library folder for new or changed files (⌘R)")
                                    .accessibilityIdentifier("v2.library.rescan")
                                Button("Change Library…", action: chooseLibrary).buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(AstroTokens.Spacing.compact)
                    }
                }
            }
        }
        .navigationTitle("Library")
        .accessibilityLabel("Library")
        .accessibilityIdentifier("v2.detail.library")
    }
}
