import AstroApplication
import SwiftUI

public struct NightsView: View {
    let snapshot: LibrarySnapshot?
    @Bindable var store: NightsStore
    let chooseLibrary: () -> Void

    public var body: some View {
        WorkspacePage(eyebrow: "Capture history", title: "Nights", subtitle: "Review each observing night without losing its series boundaries.") {
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(title: "Observed nights", value: snapshot.map { "\($0.nightCount)" } ?? "—", detail: "Detected date-based sessions", systemImage: "calendar")
                MetricCard(title: "Frames", value: snapshot.map { "\($0.frameCount)" } ?? "—", detail: "Indexed read-only", systemImage: "photo.stack")
            }
            GroupBox("Session model") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("A night can contain multiple OSC, narrowband, exposure, and filter series.", systemImage: "square.stack.3d.up")
                    Label("Quality and reports stay comparable per series and roll up to the night.", systemImage: "chart.line.uptrend.xyaxis")
                    if snapshot == nil { Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if !store.availableMonths.isEmpty {
                Picker("Month", selection: Binding(
                    get: { store.selectedMonth },
                    set: { store.selectMonth($0) }
                )) {
                    Text("All months").tag(String?.none)
                    ForEach(store.availableMonths, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("v2.nights.calendar")
            }
            if !store.nights.isEmpty {
                GroupBox("Observed nights") {
                    VStack(spacing: 0) {
                        ForEach(store.visibleNights) { night in
                            Button {
                                store.selectNight(store.selectedNightID == night.id ? nil : night.id)
                            } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "moon.stars.fill")
                                    .foregroundStyle(AstroTokens.Color.spectralViolet)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(night.date).font(.headline.monospacedDigit())
                                    Text(night.projectSummary).foregroundStyle(.secondary)
                                    Text("\(night.snapshot.usableFrames)/\(night.snapshot.totalFrames) usable · \(night.integrationSummary) · \(night.seriesCount) series")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: store.selectedNightID == night.id ? "chevron.up" : "chevron.down")
                                    .foregroundStyle(.secondary)
                            }
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 11)
                            if store.selectedNightID == night.id {
                                NightAcquisitionDetail(row: night)
                            }
                            if night.id != store.visibleNights.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .navigationTitle("Nights")
        .accessibilityLabel("Nights")
        .accessibilityIdentifier("v2.detail.nights")
    }
}

private struct NightAcquisitionDetail: View {
    let row: NightRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(row.snapshot.series, id: \.id) { series in
                HStack {
                    Text(row.snapshot.projects.first { $0.id == series.projectID }?.displayName ?? "Unknown project")
                        .lineLimit(1)
                    Spacer()
                    Text([series.filterName, "\(series.exposureSeconds.formatted(.number.precision(.fractionLength(0...1)))) s", series.setupDescriptor]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .accessibilityIdentifier("v2.nights.detail")
    }
}
