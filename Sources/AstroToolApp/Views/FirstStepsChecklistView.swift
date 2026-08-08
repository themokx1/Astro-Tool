import SwiftUI

/// R11-T12/F12: the "Első lépések" checklist body -- 6 rows
/// (`AppState.firstSteps`), each a pipa (done) or a circle + one-sentence
/// "miért" + action button. Embeddable directly (`FirstScanView`'s result
/// card, `TonightPage`'s dismissible top card) or wrapped in a standalone
/// sheet (`FirstStepsSheet`, reached any time from the Súgó menu).
struct FirstStepsChecklistView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(appState.firstSteps) { step in
                row(step)
            }
        }
    }

    private func row(_ step: FirstStepItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.isDone ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.callout).bold()
                Text(step.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !step.isDone {
                Button(step.actionTitle) { perform(step) }
                    .buttonStyle(.link)
                    .disabled(Self.isOperation(step.actionKind) && (appState.isBusy || appState.db == nil))
            }
        }
    }

    /// `true` for an action that kicks off a background operation (needs a
    /// `db` and shouldn't overlap another running one) -- `false` for a
    /// plain Settings-tab/page navigation, which is always safe regardless
    /// of `isBusy`.
    private static func isOperation(_ kind: FirstStepItem.ActionKind) -> Bool {
        switch kind {
        case .runScan, .runAudit, .rateAll, .measureSensor: return true
        case .openLocationSettings, .openSirilSettings: return false
        }
    }

    private func perform(_ step: FirstStepItem) {
        switch step.actionKind {
        case .runScan:
            appState.runScan()
        case .runAudit:
            appState.runAudit(includeSuspicious: appState.includeSuspiciousInScript)
        case .openLocationSettings:
            appState.settingsTab = .location
            openSettings()
        case .openSirilSettings:
            appState.settingsTab = .rating
            openSettings()
        case .rateAll:
            // R9-T6/B14's existing "Minden célpont pontozása…" batch flow --
            // same notification `Commands.swift`'s menu item posts,
            // observed by `MainShellView` (which owns the confirm/progress
            // sheet for it).
            NotificationCenter.default.post(name: .runRateAllRequested, object: nil)
        case .measureSensor:
            // Same "navigate, then trigger" pair `MainShellView`'s/
            // `OverviewSegment`'s own "Szenzor mérése…" buttons use.
            appState.currentPage = .sensor
            NotificationCenter.default.post(name: .measureSensorRequested, object: nil)
        }
    }
}

/// Standalone sheet wrapper -- "Súgó ▸ Első lépések…" (`.showFirstSteps`,
/// presented from `RootView` since the menu bar has no view-state of its
/// own, same pattern `GlossarySheet`/`SirilHelpSheet` already use).
struct FirstStepsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Első lépések").font(.headline)
                Spacer()
                Button("Bezárás") { dismiss() }
            }
            FirstStepsChecklistView()
        }
        .padding(20)
        .frame(width: 440)
    }
}
