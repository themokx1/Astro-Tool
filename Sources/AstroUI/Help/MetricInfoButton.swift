import SwiftUI

/// A small "ⓘ" popover explaining a surface's computed metrics -- what each
/// one means, in one short paragraph, with an optional "In the Glossary"
/// link straight to that term. Functional port of V1's `MetricInfoButton`
/// (same "one button per surface listing every metric" shape, since neither
/// SDK's `Table`/`GroupBox` header accepts a custom header view), but
/// self-contained rather than notification-based: it owns its own
/// `GlossaryView` sheet instead of posting to a menu-bar-owned singleton, so
/// it can be dropped into any surface (Home, Planning, Review, ...) without
/// that surface needing a reference to the window's `AppRouter`.
public struct MetricInfoButton: View {
    public struct Metric {
        public let title: LocalizedStringKey
        public let explanation: LocalizedStringKey
        /// Exact `GlossaryView.Term.name` to open from this metric row --
        /// stays `String` (a lookup key into `GlossaryView.terms`, not
        /// prose; e.g. "FWHM", "Field of view (FOV) / framing fit"). Kept
        /// optional so a plain-language metric does not grow a misleading
        /// glossary link merely for visual symmetry.
        public let glossaryTerm: String?

        public init(title: LocalizedStringKey, explanation: LocalizedStringKey, glossaryTerm: String? = nil) {
            self.title = title
            self.explanation = explanation
            self.glossaryTerm = glossaryTerm
        }
    }

    public let metrics: [Metric]

    @State private var showsPopover = false
    @State private var showsGlossary = false
    @State private var glossaryAnchor: String?

    public init(metrics: [Metric]) {
        self.metrics = metrics
    }

    public var body: some View {
        Button {
            showsPopover = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .help("What these measured columns mean")
        .accessibilityLabel("Metric explanations")
        .accessibilityIdentifier("v2.help.metric-info")
        .popover(isPresented: $showsPopover) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(metric.title).font(.subheadline.bold())
                                Text(metric.explanation).font(.caption).foregroundStyle(.secondary)
                                if let term = metric.glossaryTerm {
                                    Button("In the Glossary") {
                                        glossaryAnchor = term
                                        showsPopover = false
                                        showsGlossary = true
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                Divider()
                Button("Glossary…") {
                    glossaryAnchor = nil
                    showsPopover = false
                    showsGlossary = true
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            }
            .frame(width: 320, height: 360)
        }
        .sheet(isPresented: $showsGlossary) {
            GlossaryView(anchor: glossaryAnchor, dismiss: { showsGlossary = false })
        }
    }
}
