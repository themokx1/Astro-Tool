import AppKit
import AstroCore
import Foundation
import UniformTypeIdentifiers

extension AppState {
    /// Produces a support snapshot from aggregates already loaded in memory.
    /// The core model intentionally has no fields that could accept private
    /// library content, so this cannot accidentally export it later.
    var supportDiagnostics: SupportDiagnostics {
        SupportDiagnostics(
            databaseSchemaVersion: db == nil ? nil : Database.currentSchemaVersion,
            libraryConnected: db != nil,
            targetCount: stats.count,
            sessionCount: stats.reduce(0) { $0 + $1.sessionDates.count },
            filterProfileCount: filterProfiles.count,
            sensorProfileCount: sensorProfiles.count,
            weatherEnabled: config.weather.enabled,
            recentOperations: activityLog.prefix(10).map { entry in
                SupportDiagnostics.RecentOperation(
                    date: entry.date,
                    kind: Self.supportOperationKind(for: entry.title),
                    succeeded: {
                        if case .ok = entry.outcome { return true }
                        return false
                    }()
                )
            }
        )
    }

    func copySupportDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(supportDiagnostics.plainText, forType: .string)
        pushToast(.success, "A biztonságos diagnosztika a vágólapra került.")
    }

    func saveSupportDiagnostics() {
        let snapshot = supportDiagnostics
        let panel = NSSavePanel()
        panel.title = "Diagnosztika mentése"
        panel.nameFieldStringValue = snapshot.suggestedFilename
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try snapshot.plainText.write(to: url, atomically: true, encoding: .utf8)
            pushToast(.success, "Diagnosztika elmentve.")
        } catch {
            pushToast(.error, "A diagnosztika nem menthető. Válassz másik mappát.")
        }
    }

    private static func supportOperationKind(for title: String) -> SupportDiagnostics.RecentOperation.Kind {
        let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if normalized.contains("beolvas") || normalized.contains("scan") { return .scan }
        if normalized.contains("audit") || normalized.contains("integritas") { return .audit }
        if normalized.contains("pontoz") || normalized.contains("minoseg") || normalized.contains("szenzor") { return .quality }
        if normalized.contains("terv") || normalized.contains("felfedez") || normalized.contains("expozicio") { return .planning }
        if normalized.contains("export") || normalized.contains("riport") || normalized.contains("script") { return .export }
        if normalized.contains("mentes") || normalized.contains("letrehozas") || normalized.contains("torles") || normalized.contains("besorolas") { return .configuration }
        if normalized.contains("betoltes") || normalized.contains("szamitas") || normalized.contains("plate-solve") || normalized.contains("konverzio") { return .analysis }
        return .other
    }
}
