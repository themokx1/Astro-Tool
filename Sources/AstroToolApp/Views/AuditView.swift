import AstroCore
import SwiftUI

struct AuditView: View {
    @Environment(AppState.self) private var appState
    @State private var severityFilter: SeverityFilter = .all
    @State private var categoryFilter: String = ""

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

    private struct Row: Identifiable {
        let id = UUID()
        let finding: Finding
    }

    private var filteredRows: [Row] {
        appState.findings
            .filter { finding in
                if let wanted = severityFilter.severity, finding.severity != wanted { return false }
                if !categoryFilter.isEmpty, !finding.category.localizedCaseInsensitiveContains(categoryFilter) { return false }
                return true
            }
            .map(Row.init)
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

            Table(filteredRows) {
                TableColumn("") { row in
                    severityIcon(row.finding.severity)
                }
                .width(28)

                TableColumn("Kategória") { row in
                    Text(row.finding.category)
                }
                .width(min: 140, ideal: 180)

                TableColumn("Útvonal") { row in
                    Text(row.finding.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.finding.path)
                }
                .width(min: 180, ideal: 280)

                TableColumn("Üzenet") { row in
                    Text(row.finding.message)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.finding.message)
                }
            }
        }
        .padding()
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
