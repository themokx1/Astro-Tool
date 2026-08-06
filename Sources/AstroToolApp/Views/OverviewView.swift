import AstroCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppState.self) private var appState

    @State private var showNewSessionSheet = false
    @State private var showDSSIngestAlert = false

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
                projectsSection
                tonightSection
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
        .onChange(of: appState.dssIngestSummary) { _, newValue in
            showDSSIngestAlert = newValue != nil
        }
        .alert("DSS-adatok beolvasva", isPresented: $showDSSIngestAlert, presenting: appState.dssIngestSummary) { _ in
            Button("OK") {}
        } message: { summary in
            Text(
                "info.txt: \(summary.infoFilesParsed), rating: \(summary.ratingsUpserted), "
                    + ".dssfilelist: \(summary.filelistsParsed), döntés: \(summary.verdictsRecorded), "
                    + "kihagyva: \(summary.skipped)"
            )
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
                Button("Új session…") { showNewSessionSheet = true }
                    .disabled(appState.db == nil)
                if appState.hasDSSFilelists {
                    Button("DSS-döntések importálása") { appState.runIngestDSS() }
                        .disabled(appState.isBusy || appState.db == nil)
                }
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

    /// "Projektek": per-phase counts as colored chips, plus the top 3
    /// actionable (non-`.done`) targets with their first to-do -- the
    /// answer to "cloudy tonight, what should I work on?". Refreshed
    /// automatically after a scan (`AppState.runScan()`), with a manual
    /// "Frissítés" button for whenever tags/goals change without a rescan.
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projektek").font(.headline)
                Spacer()
                Button("Frissítés") { appState.loadProjects() }
                    .disabled(appState.isBusy || appState.db == nil)
            }

            if appState.projectStates.isEmpty {
                Text("Még nincs számolva — kattints a Frissítésre.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 24) {
                    statBadge("Gyűjtés", "\(projectCount(.collecting))", .blue)
                    statBadge("Stackelhető", "\(projectCount(.readyToStack))", .yellow)
                    statBadge("Feldolgozásra vár", "\(projectCount(.stacked))", .orange)
                    statBadge("Kész", "\(projectCount(.done))", .green)
                }
                let actionable = appState.projectStates.filter { $0.phase != .done }.prefix(3)
                if actionable.isEmpty {
                    Text("Minden célpont kész.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(actionable), id: \.target) { row in
                        projectRow(row)
                    }
                }
            }
        }
    }

    private func projectCount(_ phase: ProjectPhase) -> Int {
        appState.projectStates.filter { $0.phase == phase }.count
    }

    private func projectRow(_ row: ProjectState) -> some View {
        HStack(spacing: 12) {
            Text(row.target)
                .frame(minWidth: 140, alignment: .leading)
            phaseChip(row.phase)
            Text(row.todos.first ?? "-")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
    }

    private func phaseChip(_ phase: ProjectPhase) -> some View {
        Text(phaseLabel(phase))
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(phaseColor(phase).opacity(0.15), in: Capsule())
            .foregroundStyle(phaseColor(phase))
    }

    private func phaseLabel(_ phase: ProjectPhase) -> String {
        switch phase {
        case .collecting: return "gyűjtés"
        case .readyToStack: return "stackelhető"
        case .stacked: return "feldolgozásra vár"
        case .done: return "kész"
        }
    }

    private func phaseColor(_ phase: ProjectPhase) -> Color {
        switch phase {
        case .collecting: return .blue
        case .readyToStack: return .yellow
        case .stacked: return .orange
        case .done: return .green
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
                Button("Hónap…") { appState.currentPage = .calendar }
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
            Text(row.displayName)
                .lineLimit(1)
                .help(row.displayName != row.target ? row.target : "")
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
