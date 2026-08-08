import Foundation
import AstroCore
import SwiftUI

/// R11-T14/F9: the Audit page toolbar's "Integritás-ellenőrzés…" confirmation
/// sheet -- explains what the check actually does (re-reads EVERY indexed
/// file), gives a rough order-of-magnitude time estimate from the file
/// count, and offers a "Csak minta (10%)" shortcut before handing off to
/// `AppState.runVerify`'s existing `beginOperation`/progress/"Mégse"
/// infrastructure (same as every other batch operation in this app).
struct VerifyConfirmationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// DB-only coverage snapshot taken when the sheet opens.
    let coverage: FixityVerifier.Coverage

    @State private var sampleOnly = false

    /// The file count the estimate/run actually reflects once "Csak minta"
    /// is on -- matches `FixityVerifier.eligibleFiles`'s own rounding
    /// (`round(count * percent / 100)`, minimum 1).
    private var effectiveFileCount: Int {
        guard sampleOnly, coverage.hashed > 0 else { return coverage.hashed }
        return max(1, Int((Double(coverage.hashed) * 0.1).rounded()))
    }

    /// Durva ökölszabály, nem mért érték: ~300 fájl/perc egy óvatos,
    /// külső/lassabb lemezt is feltételező becslés (a tényleges sebesség a
    /// fájlméretektől és a lemez sebességétől függ) -- csak nagyságrendet ad,
    /// nem ígéretet.
    private var estimateText: String {
        guard effectiveFileCount > 0 else { return "Nincs mit ellenőrizni." }
        let minutes = max(1, Int((Double(effectiveFileCount) / 300.0).rounded(.up)))
        if minutes < 60 {
            return "\(effectiveFileCount) fájl — ez akár \(minutes) percig is tarthat"
        }
        let hours = max(1, Int((Double(minutes) / 60.0).rounded(.up)))
        return "\(effectiveFileCount) fájl — ez akár \(hours) óráig is tarthat"
    }

    private var coverageText: String {
        "\(coverage.hashed) fájlnak van ellenőrző-összege \(coverage.tracked)-ből "
            + "(\(String(format: "%.1f", coverage.percent))%)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Integritás-ellenőrzés").font(.headline)
            Text(
                "Minden indexelt, korábban ellenőrző-összeggel ellátott fájlt újraolvas, és összeveti a "
                    + "tárolt tartalom-hash-sel. Csak olvas — semmit nem javít, mozgat vagy töröl; egy "
                    + "esetleges eltérést csak jelöl, a visszaállítás biztonsági mentésből a te dolgod marad."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(estimateText)
                .font(.callout)

            Text(coverageText)
            .font(.callout)
            .foregroundStyle(.secondary)

            Toggle("Csak minta (10%)", isOn: $sampleOnly)

            HStack {
                Spacer()
                Button("Mégse") { dismiss() }
                Button("Hiányzó összegek pótlása") {
                    appState.runVerifyBaseline()
                    dismiss()
                }
                .disabled(coverage.unhashed == 0)
                Button("Ellenőrzés") {
                    appState.runVerify(samplePercent: sampleOnly ? 10 : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(coverage.hashed == 0)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
