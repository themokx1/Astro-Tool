import AppKit
import AstroCore
import Foundation
import SwiftUI

/// R9-T4/B10 -- Settings ▸ Helyszín tab (spec A.7's new row). Makes the
/// Planner's observing site -- previously invisible, silently derived from
/// FITS `SITELAT`/`SITELONG` headers whenever `config.site` was unset, per
/// the review's ground-truth finding ("`config.json` nem létezik → `site`
/// üres → a Tervező a FITS-fejlécekre támaszkodik, láthatatlanul") --
/// editable, and pairs with `AppState.loadPlan`'s fix (`resolvedSite`, not
/// `config.site`, holds the derived value) so that saving in "Automatikus"
/// mode writes an honest EMPTY `site: {}`, never whatever happened to be
/// derived from the library at the moment "Mentés" was pressed.
struct LocationSettingsView: View {
    @Environment(AppState.self) private var appState

    private enum UseMode: Hashable {
        case automatic
        case manual
    }

    @State private var mode: UseMode = .automatic
    @State private var latitudeText: String = ""
    @State private var longitudeText: String = ""

    @State private var saveMessage: String?
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                Picker("Használat", selection: $mode) {
                    Text("Automatikus (FITS-fejlécekből)").tag(UseMode.automatic)
                    Text("Kézi").tag(UseMode.manual)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Koordináták") {
                if mode == .automatic {
                    LabeledContent("Szélesség (°)", value: resolvedLatitudeText)
                    LabeledContent("Hosszúság (°)", value: resolvedLongitudeText)
                    Text("a könyvtár SITELAT/SITELONG mediánja")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Szélesség (°)", text: $latitudeText)
                    TextField("Hosszúság (°)", text: $longitudeText)
                    Button("Beillesztés a vágólapról") { pasteFromClipboard() }
                        .help("Formátum: 47.5000, 19.0400")
                }
            }

            Section {
                Text(
                    "Ez határozza meg a kulminációt, a magasságot és a csillagászati "
                        + "szürkületet a Ma este oldalon."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Mentés") { save() }
                    if let saveMessage {
                        Text(saveMessage).foregroundStyle(.green)
                    }
                    if let saveError {
                        Text(saveError).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadFromConfig() }
    }

    private var resolvedLatitudeText: String {
        appState.resolvedSite.latitudeDeg.map { String(format: "%.4f", $0) } ?? "-"
    }

    private var resolvedLongitudeText: String {
        appState.resolvedSite.longitudeDeg.map { String(format: "%.4f", $0) } ?? "-"
    }

    /// "Kézi" whenever `config.site` already carries an explicit value (a
    /// previous manual save); otherwise "Automatikus", pre-filling the text
    /// fields with whatever's currently RESOLVED so switching to "Kézi"
    /// starts from a sensible value instead of blank `0.0000` fields.
    private func loadFromConfig() {
        let site = appState.config.site
        if let lat = site.latitudeDeg, let lon = site.longitudeDeg {
            mode = .manual
            latitudeText = String(format: "%.4f", lat)
            longitudeText = String(format: "%.4f", lon)
        } else {
            mode = .automatic
            latitudeText = appState.resolvedSite.latitudeDeg.map { String(format: "%.4f", $0) } ?? ""
            longitudeText = appState.resolvedSite.longitudeDeg.map { String(format: "%.4f", $0) } ?? ""
        }
    }

    /// Parses the "47.5000, 19.0400" clipboard convention (spec A.7) -- two
    /// comma-separated decimal numbers, latitude first. A no-op (fields left
    /// untouched) for anything else on the clipboard.
    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return }
        latitudeText = String(format: "%.4f", lat)
        longitudeText = String(format: "%.4f", lon)
    }

    private func save() {
        saveMessage = nil
        saveError = nil

        var newConfig = appState.config
        if mode == .automatic {
            // The fix this task exists for: an empty `SiteRule()`, not
            // whatever `resolvedSite` currently holds.
            newConfig.site = SiteRule()
        } else {
            guard let lat = Double(latitudeText), let lon = Double(longitudeText) else {
                saveError = "Érvénytelen koordináta."
                return
            }
            newConfig.site = SiteRule(latitudeDeg: lat, longitudeDeg: lon)
        }

        do {
            let writeGuard = WriteGuard(root: URL(fileURLWithPath: newConfig.rootPath, isDirectory: true))
            try newConfig.save(using: writeGuard)
            appState.config = newConfig
            saveMessage = "Mentve."
        } catch let error as AstroError {
            saveError = describe(error)
        } catch {
            saveError = "\(error)"
        }
    }

    private func describe(_ error: AstroError) -> String {
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
}
