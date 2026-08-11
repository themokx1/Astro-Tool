import SwiftUI

public struct HomeView: View {
    @Bindable private var store: HomeStore
    private let exploreLibrary: () -> Void

    public init(store: HomeStore, openLibrary: @escaping () -> Void) {
        _store = Bindable(store)
        exploreLibrary = openLibrary
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
                header
                NightContextRail(context: store.snapshot.nightContext)
                emptyLibrary
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(AstroTokens.Spacing.spacious)
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
        .navigationTitle("Home")
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
            Text("Explore the Library workspace to preview projects and observing nights.")
        } actions: {
            Button("Explore Library workspace", action: exploreLibrary)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Explore Library workspace")
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
    }
}
