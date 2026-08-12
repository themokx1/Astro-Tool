import AstroApplication
import SwiftUI

struct WorkspacePage<Content: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                    Text(eyebrow.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.3)
                        .foregroundStyle(AstroTokens.Color.spectralBlue)
                    Text(title)
                        .font(.largeTitle.weight(.semibold))
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(AstroTokens.Spacing.spacious)
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.weight(.semibold).monospacedDigit())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(AstroTokens.Spacing.standard)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
                .stroke(AstroTokens.Color.hairline, lineWidth: 1)
        }
    }
}
