import AstroCore
import Foundation
import SwiftUI

/// Shared plumbing for every `Views/Settings/*.swift` tab (R9-T5/A.7/B12).

/// Human-readable Hungarian text for any `AstroError` -- every settings tab
/// does its own `config.save`, so this is centralized here instead of
/// copy-pasted per-file (as the pre-T5 `SettingsView`/`LocationSettingsView`
/// each did).
func describeSettingsError(_ error: AstroError) -> String {
    switch error {
    case .accessDenied(let path):
        return "Hozzáférés megtagadva: \(path)"
    case .volumeNotMounted(let path):
        return "A kötet nincs csatlakoztatva: \(path)"
    case .pathNotFound(let path):
        return "Az útvonal nem található: \(path)"
    case .writeForbidden(let path):
        return "Írás nem engedélyezett: \(path)"
    case .corruptFITS(let path, let reason):
        return "Sérült FITS fájl (\(path)): \(reason)"
    case .databaseError(let message):
        return "Adatbázis hiba: \(message)"
    case .sirilNotFound(let path):
        return "Siril nem található itt: \(path)"
    case .invalidInput(let reason):
        return "Érvénytelen bemenet: \(reason)"
    }
}

/// One settings row: `content`, plus a trailing `↺` reset button visible
/// ONLY when `isModified` -- B12's per-key "compare against `AstroConfig()`
/// defaults" requirement, generalized once instead of hand-rolled per
/// field. An optional one-line `caption` renders below the control, per
/// spec ("Mindegyik egysoros captionnel").
struct SettingsResetRow<Content: View>: View {
    let isModified: Bool
    var caption: String?
    let reset: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                content()
                if isModified {
                    Button(action: reset) {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Alaphelyzetbe állítás")
                }
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Editable `[String]` list with +/- buttons (spec B12: "excludedDirNames és
/// excludedPaths szerkeszthető `List`-ként (+/−), nem vesszős stringként")
/// -- shared by every list-of-strings config field across the settings
/// tabs (`excludedDirNames`/`excludedPaths`/`residuePatterns`/
/// `residueDirNames`/`toolOutputDirNames`/`wideField.*`/
/// `intentional.labels`/`stats.excludeLabels`).
struct EditableStringListView: View {
    let title: String
    @Binding var items: [String]
    var placeholder: String = "Új elem"

    @State private var newItem: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            ForEach(items.indices, id: \.self) { index in
                HStack {
                    TextField("", text: Binding(
                        get: { items.indices.contains(index) ? items[index] : "" },
                        set: { newValue in if items.indices.contains(index) { items[index] = newValue } }
                    ))
                    Button {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField(placeholder, text: $newItem)
                    .onSubmit(addNewItem)
                Button(action: addNewItem) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addNewItem() {
        let trimmed = newItem.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        items.append(trimmed)
        newItem = ""
    }
}
