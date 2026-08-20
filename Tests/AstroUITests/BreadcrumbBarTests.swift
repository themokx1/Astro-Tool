import AstroUI
import Testing

/// Wave 4 Task 2: type-level coverage for `BreadcrumbModel` -- the pure
/// crumb-building + click-to-pop logic behind `BreadcrumbBar`, exercised
/// directly against a real `AppRouter` instance rather than through
/// rendering (this repo has no ViewInspector-style harness for that).
@MainActor
@Suite("Breadcrumb bar")
struct BreadcrumbBarTests {
    @Test("Crumbs are built root-first with resolved labels, only the deepest one marked current")
    func crumbsBuildRootFirstWithResolvedLabels() {
        let path: [ContentRoute] = [.project("m31"), .projectSeries("m31-lrgb")]

        let crumbs = BreadcrumbModel.crumbs(sectionTitle: "Projects", path: path) { route in
            switch route {
            case .project: "M31"
            case .projectSeries: "600s · L"
            default: "?"
            }
        }

        #expect(crumbs.map(\.title) == ["Projects", "M31", "600s · L"])
        #expect(crumbs.map(\.isCurrent) == [false, false, true])
        #expect(crumbs.map(\.id) == [-1, 0, 1])
    }

    @Test("An empty path marks the section root itself as the current crumb")
    func emptyPathMarksTheRootCurrent() {
        let crumbs = BreadcrumbModel.crumbs(sectionTitle: "Library", path: [], label: { _ in "unused" })

        #expect(crumbs.count == 1)
        #expect(crumbs[0].id == -1)
        #expect(crumbs[0].title == "Library")
        #expect(crumbs[0].isCurrent)
    }

    @Test("Selecting the section-root crumb (id -1) pops the router's active section to root")
    func selectingRootCrumbPopsToRoot() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))
        router.push(.projectSeries("m31-lrgb"))

        BreadcrumbModel.select(-1, on: router)

        #expect(router.contentRoute == .projects)
        #expect(router.currentSectionPath.isEmpty)
    }

    @Test("Selecting a middle crumb truncates the stack to end at that depth, dropping everything deeper")
    func selectingMiddleCrumbTruncatesTheStack() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))
        router.push(.projectSeries("m31-lrgb"))

        BreadcrumbModel.select(0, on: router)

        #expect(router.contentRoute == .project("m31"))
        #expect(router.currentSectionPath == [.project("m31")])
    }

    @Test("Selecting the deepest crumb (the current one) is a no-op")
    func selectingTheCurrentCrumbIsANoOp() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))
        router.push(.projectSeries("m31-lrgb"))

        BreadcrumbModel.select(1, on: router)

        #expect(router.contentRoute == .projectSeries("m31-lrgb"))
        #expect(router.currentSectionPath == [.project("m31"), .projectSeries("m31-lrgb")])
    }

    @Test("Selecting an out-of-range crumb id leaves the stack untouched")
    func selectingAnOutOfRangeCrumbIsIgnored() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))

        BreadcrumbModel.select(5, on: router)

        #expect(router.currentSectionPath == [.project("m31")])
    }
}
