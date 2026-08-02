import AstroCore
import SwiftUI

struct NewSessionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var catalog: String = ""
    @State private var name: String = ""
    @State private var dateText: String = NewSessionSheet.today()

    private var previewTarget: String {
        Sanitizer.makeTarget(catalog: catalog, name: name)
    }

    private var dateIsValid: Bool {
        guard let parsed = SessionDateParser.parse(dateText) else { return false }
        return parsed.isCanonical
    }

    private var matchingTargets: [String] {
        guard !previewTarget.isEmpty else { return [] }
        return appState.stats
            .map(\.target)
            .filter { $0.localizedCaseInsensitiveContains(previewTarget) }
            .sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Új session létrehozása").font(.headline)

            TextField("Katalógus (pl. M45, NGC2237)", text: $catalog)
            TextField("Név (pl. Pleiades)", text: $name)

            Text("Célpont: \(previewTarget.isEmpty ? "-" : previewTarget)")
                .foregroundStyle(.secondary)

            TextField("Dátum (YYYY-MM-DD)", text: $dateText)
            if !dateIsValid {
                Text("Érvénytelen dátum — YYYY-MM-DD formátum szükséges.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !matchingTargets.isEmpty {
                Text("Meglévő hasonló célpontok:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(matchingTargets.prefix(5), id: \.self) { existing in
                    Button(existing) {
                        catalog = ""
                        name = existing
                    }
                    .buttonStyle(.link)
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Mégse") { dismiss() }
                Button("Létrehozás") {
                    appState.createSession(catalog: catalog, name: name, date: dateText)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(catalog.isEmpty || name.isEmpty || !dateIsValid || appState.isBusy)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear {
            // Existing-target autocomplete reads `appState.stats`; make sure
            // it's populated even if the user never visited the Stats tab.
            if appState.stats.isEmpty { appState.loadStats() }
        }
        .onChange(of: appState.lastCreatedSessionDir) { _, newValue in
            if newValue != nil { dismiss() }
        }
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
