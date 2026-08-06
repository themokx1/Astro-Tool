import SwiftUI

/// Placeholder for `Page.searchResults` -- T6 wires up the real global
/// search (targets/sessions/files/notes); this task only needs the page and
/// its routing slot to exist.
struct SearchResultsPage: View {
    var body: some View {
        ContentUnavailableView(
            "Kereső",
            systemImage: "magnifyingglass",
            description: Text("A globális kereső hamarosan érkezik.")
        )
    }
}
