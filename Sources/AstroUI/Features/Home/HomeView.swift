import SwiftUI
import AstroApplication

public struct HomeView: View {
    @Bindable private var store: HomeStore
    private let chooseLibrary: () -> Void
    private let openProject: (ProjectRecord) -> Void

    public init(
        store: HomeStore,
        chooseLibrary: @escaping () -> Void,
        openProject: @escaping (ProjectRecord) -> Void
    ) {
        _store = Bindable(store)
        self.chooseLibrary = chooseLibrary
        self.openProject = openProject
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
                header
                NightContextRail(context: store.snapshot.nightContext)
                if store.snapshot.libraryName == nil {
                    emptyLibrary
                } else {
                    libraryOverview
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(AstroTokens.Spacing.spacious)
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
        .navigationTitle("Home")
        .accessibilityLabel("Home")
        .accessibilityIdentifier("v2.detail.home")
    }

    private var libraryOverview: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(title: "Projects", value: "\(store.snapshot.projectCount)", detail: "In \(store.snapshot.libraryName ?? "library")", systemImage: "scope")
                MetricCard(title: "Nights", value: "\(store.snapshot.nightCount)", detail: "Indexed observing sessions", systemImage: "moon.stars")
            }
            GroupBox("Continue where it matters") {
                if let project = store.snapshot.nextProject {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.forward.circle.fill")
                            .font(.title2).foregroundStyle(AstroTokens.Color.spectralBlue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.displayName).font(.headline)
                            Text(project.phase == .collecting
                                ? "Least collected active project · \(duration(store.snapshot.nextProjectIntegrationSeconds)) so far."
                                : "Open the project and plan its first capture series.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Project") {
                            openProject(project)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.home.open-project")
                    }
                    .padding(8)
                } else {
                    Text("Create a project to start planning your next night.")
                        .foregroundStyle(.secondary).padding(8)
                }
            }
        }
        .accessibilityIdentifier("v2.home.library-overview")
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("OBSERVATORY WORKSPACE")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(AstroTokens.Color.spectralBlue)
            Text("Prepare the next clear night")
                .font(.largeTitle.weight(.semibold))
            Text("Keep plans, observing nights, and library health in one quiet workspace.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No library open", systemImage: "sparkles.rectangle.stack")
        } description: {
            Text("Choose an image folder, then explore the Library workspace through a local, read-only index.")
        } actions: {
            Button("Choose Image Library…", action: chooseLibrary)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose Image Library")
        }
        .frame(maxWidth: .infinity, minHeight: 250)
    }
}

private struct NightContextRail: View {
    let context: HomeSnapshot.NightContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Night context", systemImage: "moon.stars")
                    .font(.headline)
                Spacer()
                Text("Site not set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AstroTokens.Color.hairline)
                        .frame(height: 2)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    AstroTokens.Color.spectralBlue.opacity(0.45),
                                    AstroTokens.Color.spectralViolet.opacity(0.88),
                                    AstroTokens.Color.spectralBlue.opacity(0.45),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * 0.58, height: 2)
                        .offset(x: proxy.size.width * 0.21)
                    Circle()
                        .fill(AstroTokens.Color.spectralViolet)
                        .frame(width: 7, height: 7)
                        .offset(x: proxy.size.width * 0.495)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)

            HStack {
                Text(context.leadingLabel)
                Spacer()
                Text(context.centerLabel)
                Spacer()
                Text(context.trailingLabel)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(AstroTokens.Spacing.standard)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
                .stroke(AstroTokens.Color.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Night context: \(context.leadingLabel), \(context.centerLabel), \(context.trailingLabel). Site not set."
        )
        .accessibilityIdentifier("v2.home.night-context")
    }
}
