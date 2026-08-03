import AstroCore
import SwiftUI

/// Grouped, expandable audit results -- one row per (severity, category,
/// group) instead of one row per finding, so a single root cause (a nested
/// session tree, a `.DS_Store` repeated in every date folder, ...) reads as
/// one line with a count instead of flooding the list with dozens/hundreds
/// of near-identical rows. Grouping itself is `FindingGrouper` (shared with
/// the CLI's human audit output, so the two never drift); this view only
/// adds the expand/collapse state and presentation on top, mirroring the
/// Stats tab's `DisclosureGroup` style.
struct AuditView: View {
    @Environment(AppState.self) private var appState
    @State private var severityFilter: SeverityFilter = .all
    @State private var categoryFilter: String = ""
    /// Which groups are currently expanded -- individual findings are only
    /// built (and shown) for a key in this set, mirroring `StatsView`'s
    /// "only construct the expanded row's detail" pattern.
    @State private var expandedKeys: Set<FindingGrouper.Key> = []

    private enum SeverityFilter: String, CaseIterable, Identifiable {
        case all = "Mind"
        case sureError = "Biztos hiba"
        case suspicious = "Gyanús"
        case probablyIntentional = "Szándékos"

        var id: String { rawValue }

        var severity: Severity? {
            switch self {
            case .all: return nil
            case .sureError: return .sureError
            case .suspicious: return .suspicious
            case .probablyIntentional: return .probablyIntentional
            }
        }
    }

    private var filteredFindings: [Finding] {
        appState.findings.filter { finding in
            if let wanted = severityFilter.severity, finding.severity != wanted { return false }
            if !categoryFilter.isEmpty, !finding.category.localizedCaseInsensitiveContains(categoryFilter) { return false }
            return true
        }
    }

    /// Severity-first, then group-size-descending -- `FindingGrouper.group`
    /// already sorts this way.
    private var groups: [FindingGrouper.Group] {
        FindingGrouper.group(filteredFindings, config: appState.config)
    }

    private var hasSureError: Bool {
        appState.findings.contains { $0.severity == .sureError }
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Audit futtatása") {
                    appState.runAudit(includeSuspicious: appState.includeSuspiciousInScript)
                }
                .disabled(appState.isBusy || appState.db == nil)

                Toggle("Gyanúsak is a scriptbe", isOn: $appState.includeSuspiciousInScript)

                Button("Javaslat-script generálása") {
                    appState.generateSuggestions()
                }
                .disabled(appState.isBusy || !hasSureError)

                Spacer()

                if appState.isBusy {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                    Button("Mégse") { appState.cancelCurrentOperation() }
                }
            }

            HStack {
                Picker("Súlyosság", selection: $severityFilter) {
                    ForEach(SeverityFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(width: 240)

                TextField("Kategória szűrő", text: $categoryFilter)
                    .frame(width: 240)

                Spacer()
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            if groups.isEmpty {
                Text(appState.findings.isEmpty ? "Nincs audit-eredmény." : "Nincs találat a szűrőkre.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groups, id: \.key) { group in
                            groupRow(group)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func groupRow(_ group: FindingGrouper.Group) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedKeys.contains(group.key) },
                set: { isExpanded in
                    if isExpanded {
                        expandedKeys.insert(group.key)
                    } else {
                        expandedKeys.remove(group.key)
                    }
                }
            )
        ) {
            if expandedKeys.contains(group.key) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.findings, id: \.path) { finding in
                        findingRow(finding)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 12)
            }
        } label: {
            groupHeader(group)
        }
    }

    private func groupHeader(_ group: FindingGrouper.Group) -> some View {
        HStack(spacing: 10) {
            severityIcon(group.key.severity)

            Text(group.key.category)
                .frame(minWidth: 160, alignment: .leading)

            Text(group.key.groupKey)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.key.groupKey)
                .frame(minWidth: 200, maxWidth: 320, alignment: .leading)

            Text("\(group.count) fájl")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))

            Text(group.firstMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(group.firstMessage)
        }
    }

    private func findingRow(_ finding: Finding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(finding.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(finding.path)
                .frame(minWidth: 200, maxWidth: 360, alignment: .leading)
            Text(finding.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func severityIcon(_ severity: Severity) -> some View {
        switch severity {
        case .sureError:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .suspicious:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .probablyIntentional:
            Image(systemName: "checkmark.circle").foregroundStyle(.gray)
        }
    }
}
