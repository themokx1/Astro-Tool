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
            Button("Naptár") { AppState.shared?.currentPage = .calendar }
                .keyboardShortcut("2", modifiers: .command)
            Button("Minden célpont") { AppState.shared?.currentPage = .allTargets }
                .keyboardShortcut("3", modifiers: .command)
            Button("Kalibráció") { AppState.shared?.currentPage = .calibration }
                .keyboardShortcut("4", modifiers: .command)
            Button("Audit") { AppState.shared?.currentPage = .audit }
                .keyboardShortcut("5", modifiers: .command)
            Button("Szenzor") { AppState.shared?.currentPage = .sensor }
                .keyboardShortcut("6", modifiers: .command)

            Divider()

            Button("Oldalsáv") {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
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

            // T6 wires these against the real batch operations; kept here
            // (disabled) so the menu's final shape already exists.
            Button("Minden célpont pontozása…") {}
                .disabled(true)
            Button("Minden célpont exportálása…") {}
                .disabled(true)
        }

        CommandGroup(replacing: .help) {
            Button("Mappastruktúra súgó") {
                NotificationCenter.default.post(name: .showFolderStructureHelp, object: nil)
            }
            Button("Tutorial") { NSWorkspace.shared.open(tutorialURL) }
            Button("CLI-referencia") { NSWorkspace.shared.open(cliReferenceURL) }
        }
    }
}
