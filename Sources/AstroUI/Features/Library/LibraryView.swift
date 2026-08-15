import AstroApplication
import SwiftUI

public struct LibraryView: View {
    let snapshot: LibrarySnapshot?
    let rootURL: URL?
    let chooseLibrary: () -> Void
    let convertSession: () -> Void
    let rescan: () -> Void
    /// V2 UI/UX audit (2026-08-14) section 4: this view used to render a
    /// hardcoded "Read-only access" label unconditionally, even when
    /// `v2.library.enableWriteOperations` is on -- exactly this page's own
    /// promise is "your files are safe", so it must not misreport its own
    /// access mode. Reads the same `UserDefaults` key `V2RootView`'s
    /// `libraryAccessMode` and `HealthView`/`CalibrationView` already use,
    /// rather than needing a new initializer parameter threaded through
    /// `V2RootView`'s `LibraryView(...)` call site.
    @AppStorage("v2.library.enableWriteOperations") private var enableWriteOperations = false

    private var accessMode: LibraryAccessMode {
        enableWriteOperations ? .mutationEnabled : .readOnly
    }

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
                        .accessibilityIdentifier("v2.library.choose")
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
                                if accessMode == .mutationEnabled {
                                    Label("Writable", systemImage: "lock.open").foregroundStyle(.secondary)
                                } else {
                                    Label("Read-only access", systemImage: "lock.shield").foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Button("Organize One Session…", action: convertSession)
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("v2.library.convert-session")
                                Button("Rescan", systemImage: "arrow.clockwise", action: rescan)
                                    .buttonStyle(.bordered)
                                    .help("Re-read the library folder for new or changed files (⌘R)")
                                    .accessibilityIdentifier("v2.library.rescan")
                                Button("Change Library…", action: chooseLibrary).buttonStyle(.bordered)
                                    .accessibilityIdentifier("v2.library.change")
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
