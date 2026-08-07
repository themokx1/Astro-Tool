import AppKit
import SwiftUI

extension Notification.Name {
    /// "Új session… ⌘N" -- needs to present a sheet, which is local `@State`
    /// on `MainShellView`/`DetailContainerView`, not something `AppState`
    /// itself tracks; the menu command posts, the view listens.
    static let newSession = Notification.Name("AstroTool.newSession")
    /// "Mappastruktúra súgó" -- same reasoning: the sheet is presented from
    /// `RootView` (the one place still on screen in every `RootStatus`),
    /// not `AppState`.
    static let showFolderStructureHelp = Notification.Name("AstroTool.showFolderStructureHelp")
    /// "Súgó ▸ Fogalomtár" (R9-T6/B16(b)) -- same reasoning as
    /// `showFolderStructureHelp`: the sheet is presented from `RootView`,
    /// not `AppState`.
    static let showGlossary = Notification.Name("AstroTool.showGlossary")
    /// "Súgó ▸ A Sirilről…" (R11-T3/F11(c)/F20) -- same reasoning as
    /// `showGlossary`: the menu bar has no view-state of its own, so it
    /// posts, and `RootView` (always on screen) is the one place that
    /// listens and presents `SirilHelpSheet`.
    static let showSirilHelp = Notification.Name("AstroTool.showSirilHelp")
}

private let tutorialURL = URL(string: "https://themokx1.github.io/Astro-Tool/tutorial.html")!
private let cliReferenceURL = URL(string: "https://themokx1.github.io/Astro-Tool/cli.html")!

/// The app's menu bar (R9-T1, spec A.8). Commands run outside the normal
/// view hierarchy, so they can't use `@Environment(AppState.self)` --
/// `AppState.shared` (set once from `AppState.init()`) is the pragmatic,
/// documented exception. Anything that needs to touch view-local state
/// instead of `AppState` (a sheet, the sidebar's search field, the split
/// view's column visibility) goes through a `Notification` that the
/// relevant view observes.
struct AstroToolCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Új session…") {
                NotificationCenter.default.post(name: .newSession, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(AppState.shared?.db == nil)

            Divider()

            Button("Mappa választása…") {
                AppState.shared?.chooseRoot()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            if let recentRoots = AppState.shared?.recentRoots, !recentRoots.isEmpty {
                Menu("Legutóbbi könyvtárak") {
                    ForEach(recentRoots) { recent in
                        Button(URL(fileURLWithPath: recent.path, isDirectory: true).lastPathComponent) {
                            AppState.shared?.selectRecentRoot(recent)
                        }
                    }
                }
            }

            Button("Beolvasás") {
                AppState.shared?.runScan()
            }
            .keyboardShortcut("r", modifiers: .command)
            // R10 review: also disabled mid-scan (matching `MainShellView`'s
            // `staleScanBanner` "Beolvasás" button) -- without this, ⌘R
            // could silently re-fire the scan while one is already running.
            .disabled(AppState.shared?.db == nil || AppState.shared?.isBusy == true)
        }

        CommandGroup(after: .toolbar) {
            // R10 review: renumbered ⌘1-⌘9 to match `SidebarView`'s actual
            // top-to-bottom row order exactly (Ma este, Naptár, Felfedezés,
            // then KÖNYVTÁR's Minden célpont/Éjszakák, then ÁLLAPOT's
            // Kalibráció/Audit/Takarítás, then ESZKÖZÖK's Szenzor) -- the
            // previous numbering had "Felfedezés" tacked on at the end
            // (⌘9) even though the sidebar already placed it third.
            Button("Ma este") { AppState.shared?.currentPage = .tonight }
                .keyboardShortcut("1", modifiers: .command)
            // D25: `Page.calendar` is its own case -- `MainShellView.page(for:)`
            // is what preselects `tonightSegment`, same pattern `SidebarView`'s
            // "Naptár" row now uses too.
            Button("Naptár") {
                AppState.shared?.currentPage = .calendar
            }
            .keyboardShortcut("2", modifiers: .command)
            Button("Felfedezés") { AppState.shared?.currentPage = .discover }
                .keyboardShortcut("3", modifiers: .command)
            Button("Minden célpont") { AppState.shared?.currentPage = .allTargets }
                .keyboardShortcut("4", modifiers: .command)
            Button("Éjszakák") { AppState.shared?.currentPage = .nights }
                .keyboardShortcut("5", modifiers: .command)
            Button("Kalibráció") { AppState.shared?.currentPage = .calibration }
                .keyboardShortcut("6", modifiers: .command)
            Button("Audit") { AppState.shared?.currentPage = .audit }
                .keyboardShortcut("7", modifiers: .command)
            // D25: `Page.cleanup` is its own case -- same
            // `MainShellView.page(for:)`-preselects-the-segment shape as
            // "Naptár"/`.calendar` above.
            Button("Takarítás") {
                AppState.shared?.currentPage = .cleanup
            }
            .keyboardShortcut("8", modifiers: .command)
            Button("Szenzor") { AppState.shared?.currentPage = .sensor }
                .keyboardShortcut("9", modifiers: .command)

            Divider()

            // R10 review: navigates to the search-results page itself,
            // distinct from "Kereső fókuszálása" (⌘F, `CommandGroup(after:
            // .pasteboard)` below) which only focuses the sidebar's search
            // field. No shortcut of its own -- ⌘1-9 above are all taken and
            // this is a rarely-needed extra route back to results already
            // reachable via the sidebar's "Keresés" row. Disabled until a
            // search has actually run this session, same gate
            // `SidebarView`'s own "Keresés" row uses.
            Button("Keresés") {
                AppState.shared?.currentPage = .searchResults
            }
            .disabled(AppState.shared?.searchQuery.isEmpty ?? true)

            Divider()

            Button("Oldalsáv") {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            // R9-D4: `.focusSearchField` (`SidebarView`) previously had no
            // poster at all -- the sidebar's search field could only ever
            // be focused by clicking into it. R10 review: renamed from
            // "Keresés" to "Kereső fókuszálása" so it reads distinctly from
            // the View-menu "Keresés" item above (that one navigates to
            // `Page.searchResults`; this one just focuses the field).
            Button("Kereső fókuszálása") {
                NotificationCenter.default.post(name: .focusSearchField, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("Műveletek") {
            Button("Audit futtatása") {
                guard let appState = AppState.shared else { return }
                appState.runAudit(includeSuspicious: appState.includeSuspiciousInScript)
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(AppState.shared?.db == nil)

            // R9-T2/A.8: same "skip content hashing" fast path as the Audit
            // page toolbar's Menu item, exposed at the menu-bar level too.
            Button("Duplikátum-keresés nélkül auditálás") {
                guard let appState = AppState.shared else { return }
                appState.runAudit(includeSuspicious: appState.includeSuspiciousInScript, includeDuplicates: false)
            }
            .disabled(AppState.shared?.db == nil)

            Divider()

            // R9-T6/B14: real batch operations. This menu has no local view
            // state to hold a confirm sheet or a results sheet itself, so
            // items that need one post a `Notification`
            // `MainShellView`/`SensorPage` observe (same pattern "Új
            // session…" above already uses); items that just run
            // (plate-solve-all, same as `TonightPage`'s own button) call
            // `AppState` directly.
            // R10 review: `|| isBusy` added to this and the three buttons
            // below -- matching their toolbar twins (`MainShellView`'s
            // "Műveletek" menu / `TonightPage`'s plate-solve button) --
            // so a running batch operation can't be silently re-triggered
            // or canceled-and-replaced from the menu bar.
            Button("Minden célpont pontozása…") {
                NotificationCenter.default.post(name: .runRateAllRequested, object: nil)
            }
            .disabled((AppState.shared?.stats.isEmpty ?? true) || AppState.shared?.isBusy == true)

            Button("Plate-solve minden koordináta nélküli célpontra…") {
                AppState.shared?.runPlateSolveAll()
            }
            .disabled(AppState.shared?.db == nil || AppState.shared?.isBusy == true)

            Button("Szenzor mérése…") {
                AppState.shared?.currentPage = .sensor
                NotificationCenter.default.post(name: .measureSensorRequested, object: nil)
            }
            .disabled(AppState.shared?.db == nil || AppState.shared?.isBusy == true)

            if AppState.shared?.hasDSSFilelists == true {
                Button("DSS-döntések importálása") {
                    AppState.shared?.runIngestDSS()
                }
                .disabled(AppState.shared?.isBusy ?? true)
            }

            Divider()

            Button("Expozíció-tanácsadó minden célpontra…") {
                NotificationCenter.default.post(name: .adviseAllRequested, object: nil)
            }
            .disabled(AppState.shared?.db == nil || AppState.shared?.isBusy == true)
        }

        CommandGroup(replacing: .help) {
            Button("Mappastruktúra súgó") {
                NotificationCenter.default.post(name: .showFolderStructureHelp, object: nil)
            }
            Button("Fogalomtár") {
                NotificationCenter.default.post(name: .showGlossary, object: nil)
            }
            Button("A Sirilről…") {
                NotificationCenter.default.post(name: .showSirilHelp, object: nil)
            }
            Button("Tutorial") { NSWorkspace.shared.open(tutorialURL) }
            Button("CLI-referencia") { NSWorkspace.shared.open(cliReferenceURL) }
        }
    }
}
