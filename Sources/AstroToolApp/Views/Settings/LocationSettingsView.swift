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
///
/// R11-T15/F16: "Kézi" is no longer a single lat/lon pair -- it's a named
/// list (`config.sites: [SiteProfile]`), one of which is flagged "alapért."
/// (the star toggle below) as the Planner's default absent a `--site`/
/// site-Picker override. Saving still writes the legacy `config.site`
/// mirror alongside the new list (the default entry's coordinate), so an
/// older CLI build reading only `site` keeps working against a config.json
/// this tab wrote (see `AstroConfig.sites`'s own doc comment for the full
/// backward-compatibility contract).
struct LocationSettingsView: View {
    @Environment(AppState.self) private var appState

    private enum UseMode: Hashable {
        case automatic
        case manual
    }

    /// One in-progress row of the "Kézi helyszínek" list editor. A stable
    /// `UUID` (not `name`) backs `Identifiable` -- `SiteProfile.id` is the
    /// name itself, but a DRAFT row's name is exactly the thing being
    /// edited (and can transiently collide with another row's while typing),
    /// so keying the list on it would make `ForEach` reorder/misidentify
    /// rows mid-edit.
    private struct SiteDraft: Identifiable {
        let id = UUID()
        var name: String
        var latitudeText: String
        var longitudeText: String
        var isDefault: Bool
    }

    /// The comparable subset of `SiteDraft` -- `id` deliberately excluded,
    /// so `isDirty` compares by CONTENT (what `loadFromConfig()` would
    /// currently build from `appState.config.sites`) rather than by the
    /// draft-only `UUID` identity that resets every time the tab reloads.
    private struct SiteDraftSnapshot: Equatable {
        let name: String
        let latitudeText: String
        let longitudeText: String
        let isDefault: Bool
    }

    @State private var mode: UseMode = .automatic
    @State private var siteDrafts: [SiteDraft] = []
    /// R10-B6: bound to the "Időjárás-előrejelzés" section's toggle below;
    /// loaded from/saved to `config.weather.enabled` the same way `mode`/
    /// `siteDrafts` round-trip through `config.sites`/`config.site`.
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
                    Text("Kézi helyszínek").tag(UseMode.manual)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: mode) { _, newValue in
                    // Starts the list from a sensible value instead of
                    // blank fields -- same "prefill from whatever's
                    // currently RESOLVED" idea the pre-T15 single-pair form
                    // used, just as this list's first row rather than the
                    // only two text fields.
                    if newValue == .manual && siteDrafts.isEmpty {
                        siteDrafts = [starterDraft()]
                    }
                }
            }

            Section("Koordináták") {
                if mode == .automatic {
                    LabeledContent("Szélesség (°)", value: resolvedLatitudeText)
                    LabeledContent("Hosszúság (°)", value: resolvedLongitudeText)
                    Text("a könyvtár SITELAT/SITELONG mediánja")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    siteListEditor
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

    // MARK: - Site list editor (R11-T15/F16)

    private var siteListEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(siteDrafts) { draft in
                siteRow(for: draft)
            }
            Button("+ Új helyszín") { addSite() }
            Text("A csillag jelöli az alapértelmezett helyszínt -- ez számít a Ma este/Naptár tervezőben, ha nincs másik kiválasztva.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func siteRow(for draft: SiteDraft) -> some View {
        HStack(spacing: 6) {
            TextField("Név", text: binding(for: draft.id, \.name))
                .frame(minWidth: 100)
            TextField("Szélesség (°)", text: binding(for: draft.id, \.latitudeText))
                .frame(minWidth: 80)
            TextField("Hosszúság (°)", text: binding(for: draft.id, \.longitudeText))
                .frame(minWidth: 80)
            Button {
                pasteFromClipboard(into: draft.id)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.plain)
            .help("Beillesztés a vágólapról (formátum: 47.5000, 19.0400)")
            Button {
                setDefault(draft.id)
            } label: {
                Image(systemName: draft.isDefault ? "star.fill" : "star")
            }
            .buttonStyle(.plain)
            .foregroundStyle(draft.isDefault ? .yellow : .secondary)
            .help("Alapértelmezett helyszín")
            Button {
                removeSite(draft.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Helyszín törlése")
        }
    }

    /// A plain `Binding` into one draft row's field, looked up by `id` each
    /// time (rather than an `Int` index) -- safe against `siteDrafts`
    /// reordering/mutating between the getter and setter firing, same
    /// "look up by stable id, not position" the row buttons below already
    /// need for `removeSite`/`setDefault`.
    private func binding(for id: SiteDraft.ID, _ keyPath: WritableKeyPath<SiteDraft, String>) -> Binding<String> {
        Binding(
            get: { siteDrafts.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let index = siteDrafts.firstIndex(where: { $0.id == id }) else { return }
                siteDrafts[index][keyPath: keyPath] = newValue
            }
        )
    }

    private func addSite() {
        // The very first row starts out as the (only, hence trivially
        // default) site -- every subsequent addition starts unflagged, the
        // user picks a new default explicitly via the star toggle.
        siteDrafts.append(SiteDraft(name: "", latitudeText: "", longitudeText: "", isDefault: siteDrafts.isEmpty))
    }

    private func removeSite(_ id: SiteDraft.ID) {
        let wasDefault = siteDrafts.first { $0.id == id }?.isDefault ?? false
        siteDrafts.removeAll { $0.id == id }
        // Never leave the list with zero `isDefault` rows while it's still
        // non-empty -- promotes the new first entry, same fallback
        // `SiteProfile.defaultSite(in:)` itself takes defensively.
        if wasDefault, !siteDrafts.isEmpty, !siteDrafts.contains(where: \.isDefault) {
            siteDrafts[0].isDefault = true
        }
    }

    private func setDefault(_ id: SiteDraft.ID) {
        for index in siteDrafts.indices {
            siteDrafts[index].isDefault = siteDrafts[index].id == id
        }
    }

    /// Same "47.5000, 19.0400" clipboard convention (spec A.7) as before --
    /// two comma-separated decimal numbers, latitude first -- now filling
    /// ONE specific row (`id`) instead of the form's only two fields. A
    /// no-op (row left untouched) for anything else on the clipboard.
    private func pasteFromClipboard(into id: SiteDraft.ID) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              let index = siteDrafts.firstIndex(where: { $0.id == id })
        else { return }
        siteDrafts[index].latitudeText = String(format: "%.4f", lat)
        siteDrafts[index].longitudeText = String(format: "%.4f", lon)
    }

    private func starterDraft() -> SiteDraft {
        SiteDraft(
            name: "Alapértelmezett",
            latitudeText: appState.resolvedSite.latitudeDeg.map { String(format: "%.4f", $0) } ?? "",
            longitudeText: appState.resolvedSite.longitudeDeg.map { String(format: "%.4f", $0) } ?? "",
            isDefault: true
        )
    }

    /// R11-T3: factory default -- automatikus mód, üres helyszín-lista,
    /// kikapcsolt időjárás-előrejelzés (matches `SiteRule()`/`WeatherRule()`'s
    /// own defaults, same "reset the DRAFT, not the saved config" semantics
    /// as every other tab's `resetAll()` -- still needs "Mentés" to persist).
    private func resetAll() {
        mode = .automatic
        siteDrafts = []
        weatherEnabled = false
    }

    private var resolvedLatitudeText: String {
        TDFormat.cell(appState.resolvedSite.latitudeDeg.map { String(format: "%.4f", $0) })
    }

    private var resolvedLongitudeText: String {
        TDFormat.cell(appState.resolvedSite.longitudeDeg.map { String(format: "%.4f", $0) })
    }

    /// "Kézi" whenever `config.sites` already carries at least one entry (a
    /// previous manual save); otherwise "Automatikus", same "pre-fill from
    /// whatever's currently resolved" idea as before -- only now applied to
    /// the list's single starter row via `starterDraft()`.
    private func loadFromConfig() {
        let sites = appState.config.sites
        if !sites.isEmpty {
            mode = .manual
            siteDrafts = sites.map(Self.draft(from:))
        } else {
            mode = .automatic
            siteDrafts = []
        }
        weatherEnabled = appState.config.weather.enabled
    }

    private static func draft(from profile: SiteProfile) -> SiteDraft {
        SiteDraft(
            name: profile.name,
            latitudeText: String(format: "%.4f", profile.latitudeDeg),
            longitudeText: String(format: "%.4f", profile.longitudeDeg),
            isDefault: profile.isDefault
        )
    }

    /// R10-B7: "Nem mentett módosítások" indicator next to Mentés. `mode`/
    /// `weatherEnabled` compare directly against what `loadFromConfig()`
    /// would set right now; `siteDrafts` only gets compared in "Kézi" mode
    /// (the only mode where it's actually editable), by CONTENT
    /// (`SiteDraftSnapshot`, not the draft-only `UUID`s) against what
    /// `appState.config.sites` would currently produce.
    private var isDirty: Bool {
        let sites = appState.config.sites
        let loadedMode: UseMode = sites.isEmpty ? .automatic : .manual
        if mode != loadedMode { return true }
        if weatherEnabled != appState.config.weather.enabled { return true }
        guard mode == .manual else { return false }
        let loadedSnapshots = sites.map(Self.draft(from:)).map(Self.snapshot)
        let currentSnapshots = siteDrafts.map(Self.snapshot)
        return currentSnapshots != loadedSnapshots
    }

    private static func snapshot(_ draft: SiteDraft) -> SiteDraftSnapshot {
        SiteDraftSnapshot(
            name: draft.name, latitudeText: draft.latitudeText,
            longitudeText: draft.longitudeText, isDefault: draft.isDefault
        )
    }

    private func save() {
        saveMessage = nil
        saveError = nil

        var newConfig = appState.config
        if mode == .automatic {
            // The fix this task exists for (R9-T4/B10): an empty
            // `SiteRule()`, not whatever `resolvedSite` currently holds --
            // and, R11-T15/F16, an empty `sites` list too: "Automatikus"
            // means no manual site configuration persists at all.
            newConfig.site = SiteRule()
            newConfig.sites = []
        } else {
            guard !siteDrafts.isEmpty else {
                saveError = "Legalább egy helyszín szükséges Kézi módban."
                return
            }

            var profiles: [SiteProfile] = []
            var seenNames = Set<String>()
            for draft in siteDrafts {
                let trimmedName = draft.name.trimmingCharacters(in: .whitespaces)
                guard !trimmedName.isEmpty else {
                    saveError = "Minden helyszínnek nevet kell adni."
                    return
                }
                guard let lat = Double(draft.latitudeText), let lon = Double(draft.longitudeText) else {
                    saveError = "Érvénytelen koordináta: \(trimmedName.isEmpty ? "(névtelen)" : trimmedName)."
                    return
                }
                let normalizedName = trimmedName.lowercased()
                guard !seenNames.contains(normalizedName) else {
                    saveError = "Kétszer szerepel ez a helyszín-név: \(trimmedName)."
                    return
                }
                seenNames.insert(normalizedName)
                profiles.append(SiteProfile(name: trimmedName, latitudeDeg: lat, longitudeDeg: lon, isDefault: draft.isDefault))
            }

            // Defensive -- the star toggle keeps exactly one `isDefault`
            // true in normal use, but a save shouldn't depend on the UI
            // state machine never having a gap (e.g. the very first typed
            // row before any star click).
            if !profiles.contains(where: \.isDefault) {
                profiles[0].isDefault = true
            } else {
                // Exactly one -- `setDefault(_:)` already enforces this in
                // the UI, but a defensive re-normalization here costs
                // nothing and keeps `SiteProfile.defaultSite(in:)`'s own
                // "expects exactly one" assumption honest even if `profiles`
                // somehow arrived with more than one flagged.
                var foundDefault = false
                for index in profiles.indices {
                    if profiles[index].isDefault {
                        if foundDefault { profiles[index].isDefault = false } else { foundDefault = true }
                    }
                }
            }

            newConfig.sites = profiles
            // R11-T15/F16: mirrors the DEFAULT site's coordinate into the
            // legacy `site` field, kept "in sync" per the ticket's own
            // backward-compatibility spec -- an older CLI build reading
            // only `config.site` still gets a sensible single coordinate.
            if let def = SiteProfile.defaultSite(in: profiles) {
                newConfig.site = SiteRule(latitudeDeg: def.latitudeDeg, longitudeDeg: def.longitudeDeg)
            }
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
