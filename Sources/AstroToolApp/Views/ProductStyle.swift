import SwiftUI

/// Small, native design vocabulary shared by product-level surfaces. Values
/// follow an 8-point rhythm and deliberately defer color, typography and
/// materials to macOS instead of simulating another platform.
enum ProductMetrics {
    static let compact: CGFloat = 8
    static let standard: CGFloat = 12
    static let section: CGFloat = 16
    static let spacious: CGFloat = 24
    static let cardRadius: CGFloat = 14
}

struct ProductCard<Content: View>: View {
    var padding: CGFloat = ProductMetrics.section
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ProductMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ProductMetrics.cardRadius, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            }
    }
}

struct ProductEmptyState: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let title: String
    let detail: String
    let symbol: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: ProductMetrics.standard) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: accessibilityReduceMotion ? .nonRepeating : .repeating.speed(0.25))
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(ProductMetrics.spacious)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

struct ProductSectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2.weight(.semibold))
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
