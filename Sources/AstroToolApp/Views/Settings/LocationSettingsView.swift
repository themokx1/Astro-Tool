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
    /// R10-B6: bound to the "Időjárás-előrejelzés" section's toggle below;
    /// loaded from/saved to `config.weather.enabled` the same way `mode`/
    /// `latitudeText`/`longitudeText` round-trip through `config.site`.
    @State private var weatherEnabled: Bool = false

    @State private var saveMessage: String?
    @State private var saveError: String?
    /// R11-T3: this tab was the one tab of five missing the "Alaphelyzetbe
    /// állítás…" affordance the other four (`LibrarySettingsView`,
    /// `CalibrationSettingsView`, `RatingSettingsView`,
    /// `LibraryRulesSettingsView`) all already had -- same confirm-then-
    /// reset-the-draft pattern, wired up below.
    @State private var showResetConfirm = false

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

            // R10-B6: opt-in, default OFF -- see `WeatherRule`'s doc comment
            // for why this lives in `AstroConfig` at all (persisted, but
            // AstroCore itself never makes the actual network call).
            Section("Időjárás-előrejelzés") {
                Toggle("Felhőzet-előrejelzés (Open-Meteo)", isOn: $weatherEnabled)
                Text(
                    "Bekapcsolva a beállított helyszín koordinátái (2 tizedesre kerekítve) "
                        + "elküldésre kerülnek az Open-Meteo szolgáltatásnak. "
                        + "Alapértelmezés: kikapcsolva."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Alaphelyzetbe állítás…") { showResetConfirm = true }
                    Spacer()
                    if isDirty {
                        Text("Nem mentett módosítások").font(.caption).foregroundStyle(.orange)
                    }
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
        // R10 review (item 17): a fresh edit re-dirtying the draft after a
        // previous save's feedback is still showing must clear that stale
        // feedback -- otherwise "Mentve." (or a stale error) sits there
        // looking current while actually describing a DIFFERENT draft.
        // Only fires on the false -> true transition: `save()` itself
        // already sets `saveMessage`/`saveError` right as it also makes
        // `isDirty` become `false` again (a successful save syncs
        // `appState.config` to match the draft) -- reacting to EVERY
        // change here would immediately wipe that fresh feedback back out
        // before the user ever saw it, and a FAILED save leaves `isDirty`
        // unchanged (still `true`, no transition fires at all), so
        // `saveError` survives to actually be read.
        .onChange(of: isDirty) { _, newValue in
            if newValue {
                saveMessage = nil
                saveError = nil
            }
        }
        .confirmationDialog(
            "Biztosan alaphelyzetbe állítod a Helyszín beállításokat?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Alaphelyzetbe állítás", role: .destructive) { resetAll() }
        }
    }

    /// R11-T3: factory default -- automatikus mód, üres koordináták, kikapcsolt
    /// időjárás-előrejelzés (matches `SiteRule()`/`WeatherRule()`'s own
    /// defaults, same "reset the DRAFT, not the saved config" semantics as
    /// every other tab's `resetAll()` -- still needs "Mentés" to persist).
    private func resetAll() {
        mode = .automatic
        latitudeText = ""
        longitudeText = ""
        weatherEnabled = false
    }

    private var resolvedLatitudeText: String {
        TDFormat.cell(appState.resolvedSite.latitudeDeg.map { String(format: "%.4f", $0) })
    }

    private var resolvedLongitudeText: String {
        TDFormat.cell(appState.resolvedSite.longitudeDeg.map { String(format: "%.4f", $0) })
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
        weatherEnabled = appState.config.weather.enabled
    }

    /// R10-B7: "Nem mentett módosítások" indicator next to Mentés. `mode`/
    /// `weatherEnabled` compare directly against what `loadFromConfig()`
    /// would set right now; `latitudeText`/`longitudeText` only get
    /// compared in "Kézi" mode, since that's the only mode where they're
    /// actually editable at all -- in "Automatikus" mode they're a
    /// read-only mirror of `appState.resolvedSite` (via `LabeledContent`
    /// above, not a `TextField`), so they can never hold an unsaved EDIT
    /// while automatic no matter what they currently display.
    private var isDirty: Bool {
        let site = appState.config.site
        let loadedMode: UseMode = (site.latitudeDeg != nil && site.longitudeDeg != nil) ? .manual : .automatic
        if mode != loadedMode { return true }
        if weatherEnabled != appState.config.weather.enabled { return true }
        guard mode == .manual else { return false }
        let loadedLat = site.latitudeDeg.map { String(format: "%.4f", $0) } ?? ""
        let loadedLon = site.longitudeDeg.map { String(format: "%.4f", $0) } ?? ""
        return latitudeText != loadedLat || longitudeText != loadedLon
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
        newConfig.weather.enabled = weatherEnabled

        do {
            let writeGuard = WriteGuard(root: URL(fileURLWithPath: newConfig.rootPath, isDirectory: true))
            try newConfig.save(using: writeGuard)
            appState.config = newConfig
            saveMessage = "Mentve."
            // D13: the Ma este/Naptár plan (kulminál/magasság/szürkület) is
            // computed from the site at load time -- a save here used to
            // leave whatever was already on screen stale until the next
            // unrelated reload. Recompute it (respecting a date-scoped
            // "Ma este" view via `planDate`) if a plan's ever been loaded
            // this session; otherwise just refresh the "Automatikus"
            // resolved-site display for THIS tab.
            if appState.plan != nil {
                appState.loadPlan(date: appState.planDate)
            } else {
                // No plan loaded yet this session (Ma este never opened) --
                // no `Planner.resolveSite` DB round trip needed, `newConfig
                // .site` already IS the answer either way: the manually
                // entered value, or (automatic) the empty `SiteRule()` that
                // makes `resolvedLatitudeText`/`resolvedLongitudeText` show
                // "-" honestly until a real plan load resolves it from the
                // library median.
                appState.resolvedSite = newConfig.site
            }
            // R10-B6: covers "the toggle just turned on" (the task this
            // exists for) AND "already on, coordinates changed" -- either
            // way `loadWeather()`'s own guard makes this an instant no-op
            // when the toggle ended up off, and `WeatherService`'s cache
            // makes a redundant call (toggle was already on, nothing
            // relevant changed) cheap rather than a wasted network round
            // trip.
            appState.loadWeather()
        } catch let error as AstroError {
            saveError = describeSettingsError(error)
        } catch {
            saveError = "\(error)"
        }
    }
}
