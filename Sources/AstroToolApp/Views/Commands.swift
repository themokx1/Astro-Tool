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
            .disabled(AppState.shared?.db == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Ma este") { AppState.shared?.currentPage = .tonight }
                .keyboardShortcut("1", modifiers: .command)
            // R9-T4: the calendar is `TonightPage`'s own segment now, not a
            // separate page -- preselect it before navigating, same pattern
            // `SidebarView`'s "Naptár" row uses.
            Button("Naptár") {
                AppState.shared?.tonightSegment = .calendar
                AppState.shared?.currentPage = .tonight
            }
            .keyboardShortcut("2", modifiers: .command)
            Button("Minden célpont") { AppState.shared?.currentPage = .allTargets }
                .keyboardShortcut("3", modifiers: .command)
            Button("Kalibráció") { AppState.shared?.currentPage = .calibration }
                .keyboardShortcut("4", modifiers: .command)
            Button("Audit") { AppState.shared?.currentPage = .audit }
                .keyboardShortcut("5", modifiers: .command)
            // R9-D9: same "preselect a segment, then navigate" pattern
            // `SidebarView`'s "Takarítás" row already established for
            // `AppState.auditSegment` -- previously only reachable via the
            // sidebar, with no menu-bar/keyboard equivalent at all.
            Button("Takarítás") {
                AppState.shared?.auditSegment = .cleanable
                AppState.shared?.currentPage = .audit
            }
            .keyboardShortcut("6", modifiers: .command)
            Button("Szenzor") { AppState.shared?.currentPage = .sensor }
                .keyboardShortcut("7", modifiers: .command)

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
            // be focused by clicking into it.
            Button("Keresés") {
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
            Button("Minden célpont pontozása…") {
                NotificationCenter.default.post(name: .runRateAllRequested, object: nil)
            }
            .disabled(AppState.shared?.stats.isEmpty ?? true)

            Button("Plate-solve minden koordináta nélküli célpontra…") {
                AppState.shared?.runPlateSolveAll()
            }
            .disabled(AppState.shared?.db == nil)

            Button("Szenzor mérése…") {
                AppState.shared?.currentPage = .sensor
                NotificationCenter.default.post(name: .measureSensorRequested, object: nil)
            }
            .disabled(AppState.shared?.db == nil)

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
            .disabled(AppState.shared?.db == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Mappastruktúra súgó") {
                NotificationCenter.default.post(name: .showFolderStructureHelp, object: nil)
            }
            Button("Fogalomtár") {
                NotificationCenter.default.post(name: .showGlossary, object: nil)
            }
            Button("Tutorial") { NSWorkspace.shared.open(tutorialURL) }
            Button("CLI-referencia") { NSWorkspace.shared.open(cliReferenceURL) }
        }
    }
}
