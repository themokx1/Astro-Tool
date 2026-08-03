import AstroCore
import SwiftUI

/// The six main tabs, used both by the `TabView` selection and by
/// `OverviewView`'s quick-jump buttons.
enum AppTab: Hashable {
    case overview, audit, quality, calibration, stats, settings
}

struct OverviewView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: AppTab

    @State private var showNewSessionSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                rootSection
                if appState.isBusy {
                    busySection
                }
                if let scanSummary = appState.scanSummary {
                    summarySection(scanSummary)
                }
                findingsSection
                if let cleanupSummary = appState.cleanupSummary {
                    cleanupSection(cleanupSummary)
                }
                tonightSection
                quickLinksSection
                if let lastError = appState.lastError {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet()
        }
    }

    private var rootSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Könyvtár").font(.headline)
            Text(appState.config.rootPath)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            HStack {
                Button("Mappa választása…") { appState.chooseRoot() }
                Button("Könyvtár beolvasása") { appState.runScan() }
                    .disabled(appState.isBusy || appState.db == nil)
                Button("Új session…") { showNewSessionSheet = true }
                    .disabled(appState.db == nil)
            }
        }
    }

    private var busySection: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(appState.progressText)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Mégse") { appState.cancelCurrentOperation() }
        }
    }

    private func summarySection(_ summary: ScanSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Utolsó beolvasás").font(.headline)
            HStack(spacing: 24) {
                statBadge("Új", "\(summary.added)", .blue)
                statBadge("Frissült", "\(summary.updated)", .blue)
                statBadge("Változatlan", "\(summary.unchanged)", .gray)
                statBadge("Hiányzó", "\(summary.missing)", .orange)
            }
        }
    }

    private var findingsSection: some View {
        let sureErrors = appState.findings.filter { $0.severity == .sureError }.count
        let suspicious = appState.findings.filter { $0.severity == .suspicious }.count
        let intentional = appState.findings.filter { $0.severity == .probablyIntentional }.count

        return VStack(alignment: .leading, spacing: 8) {
            Text("Audit találatok").font(.headline)
            HStack(spacing: 24) {
                statBadge("Biztos hiba", "\(sureErrors)", .red)
                statBadge("Gyanús", "\(suspicious)", .yellow)
                statBadge("Szándékos", "\(intentional)", .gray)
            }
        }
    }

    private func cleanupSection(_ summary: CleanupSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Takarítás").font(.headline)
            Text("Összesen felszabadítható: \(Self.formatBytes(summary.grandTotalBytes))")
            ForEach(summary.groups.prefix(3), id: \.category) { group in
                HStack {
                    Text(group.category)
                    Spacer()
                    Text("\(group.fileCount) fájl, \(Self.formatBytes(group.totalBytes))")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Takarítási script generálása") { appState.generateCleanupScript() }
                .disabled(appState.isBusy || summary.groups.isEmpty)
        }
    }

    /// "Ma este": top 5 `TargetPlan` rows by score, with a manual refresh
    /// button (`AppState.loadPlan()` is never triggered automatically --
    /// unlike Stats/Calib, tonight's plan is time-of-day-sensitive, so an
    /// auto-refresh right after a long scan would often show a stale
    /// instant anyway).
    private var tonightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ma este").font(.headline)
                Spacer()
                Button("Frissítés") { appState.loadPlan() }
                    .disabled(appState.isBusy || appState.db == nil)
            }

            if let plan = appState.plan {
                if plan.isEmpty {
                    Text("Nincs célpont a könyvtárban.").foregroundStyle(.secondary)
                } else {
                    ForEach(plan.prefix(5), id: \.target) { row in
                        tonightRow(row)
                    }
                }
            } else {
                Text("Még nincs számolva — kattints a Frissítésre.").foregroundStyle(.secondary)
            }
        }
    }

    private func tonightRow(_ row: TargetPlan) -> some View {
        HStack(spacing: 12) {
            Text(row.target)
                .frame(minWidth: 140, alignment: .leading)
            Text(row.goalSeconds != nil ? missingHoursText(row) : "—")
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            Text(row.culminationLocal ?? "-")
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .leading)
            Text(moonText(row))
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)
            Spacer()
            verdictChip(row.verdict)
        }
        .font(.callout)
    }

    private func missingHoursText(_ row: TargetPlan) -> String {
        guard let goal = row.goalSeconds else { return "—" }
        let missingHours = max(0, (goal - row.usableIntegrationSeconds) / 3600.0)
        return String(format: "hiányzik: %.1fó", missingHours)
    }

    private func moonText(_ row: TargetPlan) -> String {
        guard let illum = row.moonIlluminationPercent else { return "-" }
        return String(format: "Hold: %.0f%%", illum)
    }

    private func verdictChip(_ verdict: String) -> some View {
        Text(verdict)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(verdictColor(verdict).opacity(0.15), in: Capsule())
            .foregroundStyle(verdictColor(verdict))
    }

    private func verdictColor(_ verdict: String) -> Color {
        if verdict == "ma jó" { return .green }
        if verdict.hasPrefix("Hold zavar") { return .yellow }
        if verdict.hasPrefix("alacsony") || verdict == "nem látszik ma éjjel" { return .orange }
        return .gray // "nincs koordináta"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private var quickLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ugrás").font(.headline)
            HStack {
                Button("Audit") { selectedTab = .audit }
                Button("Minőség") { selectedTab = .quality }
                Button("Kalibráció") { selectedTab = .calibration }
                Button("Statisztika") { selectedTab = .stats }
                Button("Beállítások") { selectedTab = .settings }
            }
        }
    }

    private func statBadge(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
