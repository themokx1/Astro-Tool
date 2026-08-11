import SwiftUI

public struct InspectorView: View {
    public let selection: LibrarySelection?
    private let hideInspector: () -> Void

    public init(
        selection: LibrarySelection?,
        hideInspector: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self.hideInspector = hideInspector
    }

    public var body: some View {
        Group {
            if let selection {
                selectionDetails(selection)
            } else {
                ContentUnavailableView {
                    Label("Nothing selected", systemImage: "sidebar.right")
                } description: {
                    Text("Select an item to inspect its metadata and context.")
                } actions: {
                    Button("Hide Inspector", action: hideInspector)
                }
            }
        }
        .frame(minWidth: 240, idealWidth: 280)
        .padding(AstroTokens.Spacing.standard)
        .accessibilityLabel("Inspector")
        .accessibilityIdentifier("v2.inspector")
    }

    @ViewBuilder
    private func selectionDetails(_ selection: LibrarySelection) -> some View {
        Form {
            Section("Selection") {
                LabeledContent("Type", value: kind(for: selection))
                LabeledContent("Identifier", value: identifier(for: selection))
            }
        }
        .formStyle(.grouped)
    }

    private func kind(for selection: LibrarySelection) -> String {
        switch selection {
        case .project: "Project"
        case .night: "Night"
        case .series: "Series"
        case .frame: "Frame"
        case .result: "Result"
        }
    }

    private func identifier(for selection: LibrarySelection) -> String {
        switch selection {
        case .project(let id), .night(let id), .series(let id), .result(let id): id
        case .frame(let id): String(id)
        }
    }
}
