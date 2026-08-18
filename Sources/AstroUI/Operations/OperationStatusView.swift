import AstroApplication
import SwiftUI

/// Toolbar control for the V2 operation backbone -- when something is
/// running (scan, audit, sensor measurement, ...) it shows that operation's
/// title, a progress indicator, and a Cancel button wired to
/// `OperationHost.cancel(id:)`; otherwise it shows a quiet icon that opens a
/// popover of recent outcomes (`OperationHost.recentOutcomes`). This is the
/// one place in V2 that surfaces "something is happening" and "something
/// just finished" outside of the toast layer, which is deliberately
/// transient.
public struct OperationStatusView: View {
    @Environment(OperationHost.self) private var operationHost
    @State private var showsPopover = false

    public init() {}

    public var body: some View {
        Button(action: { showsPopover.toggle() }) {
            if let current = operationHost.activeOperations.first {
                HStack(spacing: AstroTokens.Spacing.compact) {
                    ProgressView(value: progressFraction(for: current))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(current.title)
                        .font(.callout)
                        .lineLimit(1)
                }
            } else {
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.plain)
        // W6-D fix: `activeOperations.first?.title` is already an eagerly
        // resolved, translated `String` (every `run(kind:title:...)` call
        // site resolves its title through `OperationHost.localized(_:)`
        // before this ever reads it -- see that method's own doc comment),
        // but the "Recent activity" fallback used to be a raw English
        // literal bound straight to a `String ?? String` -- `.help(_:)`
        // then renders the whole expression verbatim regardless. Routing
        // the fallback through the same `OperationHost.localized(_:)` every
        // other title in this file already uses keeps both sides of the
        // `??` actually translated.
        .help(operationHost.activeOperations.first?.title ?? OperationHost.localized("Recent activity"))
        .accessibilityIdentifier("v2.toolbar.operations.status")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            OperationStatusPopover(operationHost: operationHost)
        }
    }

    private func progressFraction(for operation: OperationHost.ActiveOperation) -> Double? {
        guard let total = operation.total, total > 0 else { return nil }
        return Double(operation.completed) / Double(total)
    }
}

private struct OperationStatusPopover: View {
    let operationHost: OperationHost

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            if operationHost.activeOperations.isEmpty, operationHost.recentOutcomes.isEmpty {
                Text("No recent activity")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                if !operationHost.activeOperations.isEmpty {
                    Text("Running")
                        .font(.headline)
                    ForEach(operationHost.activeOperations) { operation in
                        RunningOperationRow(operationHost: operationHost, operation: operation)
                    }
                }
                if !operationHost.recentOutcomes.isEmpty {
                    Text("Recent")
                        .font(.headline)
                        .padding(.top, operationHost.activeOperations.isEmpty ? 0 : AstroTokens.Spacing.compact)
                    ForEach(operationHost.recentOutcomes) { outcome in
                        OutcomeRow(outcome: outcome)
                    }
                }
            }
        }
        .padding(AstroTokens.Spacing.standard)
        .frame(width: 320)
        .accessibilityIdentifier("v2.toolbar.operations.popover")
    }
}

private struct RunningOperationRow: View {
    let operationHost: OperationHost
    let operation: OperationHost.ActiveOperation

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .font(.callout)
                if let total = operation.total, total > 0 {
                    Text("\(operation.completed) of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if operation.cancellationPolicy != .unavailable {
                Button("Cancel") {
                    Task { await operationHost.cancel(id: operation.id) }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("v2.toolbar.operations.cancel")
            }
        }
    }
}

private struct OutcomeRow: View {
    let outcome: OperationHost.OutcomeRecord

    var body: some View {
        HStack(spacing: AstroTokens.Spacing.compact) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(outcome.title)
                .font(.callout)
                .lineLimit(1)
            Spacer()
        }
    }

    private var iconName: String {
        switch outcome.phase {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "slash.circle"
        case .running: "clock"
        }
    }

    private var iconColor: Color {
        switch outcome.phase {
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        case .running: AstroTokens.Color.accent
        }
    }
}
