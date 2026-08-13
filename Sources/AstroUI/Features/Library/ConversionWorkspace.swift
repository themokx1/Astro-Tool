import AstroApplication
import SwiftUI

@MainActor
@Observable
public final class ConversionStore {
    public private(set) var sessions: [ConversionSessionID] = []
    public private(set) var preview: ConversionPreview?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public var selection: ConversionSessionID?
    public var mode: ConversionPreviewMode = .logical
    private let useCase: ConversionUseCase

    public init(useCase: ConversionUseCase) { self.useCase = useCase }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await useCase.availableSessions()
            selection = selection ?? sessions.first
            try await refreshPreview()
        } catch { errorMessage = error.localizedDescription }
    }

    public func refreshPreview() async throws {
        guard let selection else { preview = nil; return }
        preview = try await useCase.plan(sessionID: selection, mode: mode)
    }
}

public struct ConversionWorkspace: View {
    @State private var store: ConversionStore
    @State private var step = 1
    let dismiss: () -> Void

    public init(useCase: ConversionUseCase, dismiss: @escaping () -> Void) {
        _store = State(initialValue: ConversionStore(useCase: useCase))
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: AstroTokens.Spacing.section) {
                steps
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(AstroTokens.Spacing.section)
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(.background)
        .task { await store.load() }
        .accessibilityIdentifier("v2.conversion.workspace")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.split.2x1").font(.title2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("Organize one session").font(.title2.bold())
                Text("Preview first. Your source images stay untouched.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
        }.padding(20)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepLabel(1, "Choose", "One target and night")
            stepLabel(2, "Review", "Detected capture groups")
            stepLabel(3, "Operations", "Exact impact")
        }.frame(width: 170, alignment: .topLeading)
    }

    private func stepLabel(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.bold()).frame(width: 24, height: 24)
                .background(step == number ? Color.accentColor : Color.secondary.opacity(0.18), in: Circle())
                .foregroundStyle(step == number ? .white : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if store.isLoading {
            ProgressView("Reading AstroTool's index…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage {
            ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if store.sessions.isEmpty {
            ContentUnavailableView("No sessions found", systemImage: "moon.zzz", description: Text("Scan a library containing light frames first."))
        } else {
            switch step {
            case 1: chooseStep
            case 2: reviewStep
            default: operationsStep
            }
        }
    }

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Which session should AstroTool organize?").font(.title3.bold())
            Text("Only the selected target and date are in scope. Nothing else in the library is included.")
                .foregroundStyle(.secondary)
            Picker("Session", selection: $store.selection) {
                ForEach(store.sessions, id: \.self) { session in
                    Text("\(session.target) · \(session.date)").tag(Optional(session))
                }
            }.labelsHidden().frame(maxWidth: 480)
            Label("Exactly 1 session", systemImage: "scope").foregroundStyle(.green)
            Spacer()
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Detected capture groups").font(.title3.bold())
            if let preview = store.preview {
                Text("\(preview.scope.target) · \(preview.scope.date)").foregroundStyle(.secondary)
                ForEach(preview.proposedSeries) { series in
                    HStack {
                        Image(systemName: "camera.aperture").foregroundStyle(.purple)
                        VStack(alignment: .leading) {
                            Text(series.title).font(.headline)
                            Text("\(series.frameCount) light frames").foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(14).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Spacer()
        }
    }

    private var operationsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Exact impact").font(.title3.bold())
            Picker("Organization", selection: $store.mode) {
                Text("Logical · no file moves").tag(ConversionPreviewMode.logical)
                Text("Physical · requires access").tag(ConversionPreviewMode.physical)
            }.pickerStyle(.segmented).frame(maxWidth: 460)
                .onChange(of: store.mode) { _, _ in Task { try? await store.refreshPreview() } }
            if store.mode == .logical {
                Label("0 files moved", systemImage: "checkmark.shield.fill").foregroundStyle(.green).font(.headline)
                Text("AstroTool will keep the session together and represent each exposure/filter combination as its own capture group in the app.")
            } else {
                Label("Locked preview", systemImage: "lock.fill").foregroundStyle(.orange).font(.headline)
                Text(store.preview?.authorizationMessage ?? "Explicit write access is required.")
            }
            GroupBox("Planned result") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.preview?.proposedSeries ?? []) { series in
                        Label("\(series.title) — \(series.frameCount) frames", systemImage: "folder")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if step > 1 { Button("Back") { step -= 1 } }
            Spacer()
            if step < 3 {
                Button("Continue") {
                    Task { try? await store.refreshPreview(); step += 1 }
                }.buttonStyle(.borderedProminent).disabled(store.selection == nil)
            } else {
                Button("Done", action: dismiss).buttonStyle(.borderedProminent)
                Text("Preview only").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16)
    }
}
