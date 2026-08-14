import SwiftUI

/// One rendered crumb in a `BreadcrumbBar` -- `id` is `-1` for the section
/// root crumb (the one whose click is a `popToRoot`) and otherwise the
/// crumb's own index into the section's `currentSectionPath` (the one whose
/// click truncates the stack to end at that depth). Kept as its own tiny
/// value type so `BreadcrumbModel.crumbs` is trivially unit-testable without
/// rendering any SwiftUI at all.
public struct BreadcrumbCrumb: Identifiable, Equatable {
    public let id: Int
    public let title: String
    public let isCurrent: Bool
}

/// The pure logic behind `BreadcrumbBar` -- building the crumb list from a
/// section title + push stack + label resolver, and translating "the user
/// clicked crumb N" into the router mutation that should follow. Split out
/// from the View itself so both halves are testable without rendering
/// (`BreadcrumbBarTests` exercises this directly against a real `AppRouter`
/// instance).
public enum BreadcrumbModel {
    /// Root-first: the section's own root crumb, then one crumb per pushed
    /// route in `path`, in order. The LAST crumb (the deepest one -- the
    /// section root itself when `path` is empty) is marked `isCurrent`.
    public static func crumbs(
        sectionTitle: String,
        path: [ContentRoute],
        label: (ContentRoute) -> String
    ) -> [BreadcrumbCrumb] {
        var crumbs = [BreadcrumbCrumb(id: -1, title: sectionTitle, isCurrent: path.isEmpty)]
        for (index, route) in path.enumerated() {
            crumbs.append(BreadcrumbCrumb(id: index, title: label(route), isCurrent: index == path.count - 1))
        }
        return crumbs
    }

    /// What clicking the crumb whose `id` is `crumbID` does to `router`'s
    /// ACTIVE section stack -- `-1` (the section-root crumb) always clears
    /// it entirely (`popToRoot`, the standard "jump back to the section
    /// root" gesture); any other id truncates the stack to end at that
    /// depth, exactly like repeatedly tapping the native Back chevron would,
    /// just in one step.
    @MainActor
    public static func select(_ crumbID: Int, on router: AppRouter) {
        guard crumbID >= 0 else {
            router.popToRoot()
            return
        }
        let path = router.currentSectionPath
        guard path.indices.contains(crumbID) else { return }
        router.currentSectionPath = Array(path.prefix(crumbID + 1))
    }
}

/// A clickable "Section › ... › current" breadcrumb, built from
/// `AppRouter.currentSectionPath` -- lives ABOVE the pushed content in the
/// detail column's `NavigationStack` (a `.safeAreaInset(edge: .top)` in
/// `V2RootView`'s `DetailHost`), so it stays put while the stack underneath
/// it pushes/pops, mirroring the native Back chevron rather than replacing
/// it. Deliberately dumb about WHAT a route's human label is -- `label` is
/// injected by the caller (`V2RootView.DetailHost`, which is where
/// `ProjectsStore`/`NightsStore` already live) so this view has no store
/// dependencies of its own.
public struct BreadcrumbBar: View {
    let sectionTitle: String
    let path: [ContentRoute]
    let label: (ContentRoute) -> String
    let select: (Int) -> Void

    public init(
        sectionTitle: String,
        path: [ContentRoute],
        label: @escaping (ContentRoute) -> String,
        select: @escaping (Int) -> Void
    ) {
        self.sectionTitle = sectionTitle
        self.path = path
        self.label = label
        self.select = select
    }

    public var body: some View {
        let crumbs = BreadcrumbModel.crumbs(sectionTitle: sectionTitle, path: path, label: label)
        HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if crumb.isCurrent {
                    Text(crumb.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                } else {
                    Button(crumb.title) { select(crumb.id) }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(AstroTokens.Color.spectralBlue)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AstroTokens.Spacing.spacious)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityIdentifier("v2.breadcrumb")
    }
}
