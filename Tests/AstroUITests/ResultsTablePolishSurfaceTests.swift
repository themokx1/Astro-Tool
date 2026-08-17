import Foundation
import Testing

/// W4-4 item 5 (owner review): three Results-table complaints in one pass.
///
/// 1. The Name column truncated in the MIDDLE ("mu cephei 068x300sec
///    1...le-2-0x"), which drops exactly the tail (drizzle/time) fragment
///    that makes a variant distinguishable -- the full name already lives
///    in the detail pane. SwiftUI's own truncation semantics: `.head`
///    removes characters from the BEGINNING (keeping the tail visible),
///    `.tail` removes them from the END (keeping the head) -- confirmed by
///    this codebase's own existing precedent, `ArchiveTaskCard`'s evidence-
///    path `Text`, which uses `.truncationMode(.head)` specifically to keep
///    a path's own distinguishing filename (its tail) visible while its
///    shared leading directory structure truncates away. The fix here is
///    the same `.head` mode, not `.tail` (which would do the opposite of
///    what "the tail survives" requires).
/// 2. The "Eredeti"/"Original" kind badge rendered on every parent (family)
///    row -- a column whose value never varies is noise; only variant
///    (child) rows, whose kind can actually differ, keep the badge.
/// 3. The table needed a horizontal scrollbar at the default window width;
///    Size and Night are narrowed (the owner's own suggestion) so the
///    column-width budget fits inside the `HSplitView` pane's own declared
///    `idealWidth: 440` for the table side.
///
/// Follows this repo's established "surface" suite convention: literal
/// source-text assertions rather than a rendered view (a `Table`'s own
/// pixel layout is not introspectable from a unit test).
@Suite("Results table polish (W4-4 item 5)")
struct ResultsTablePolishSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The Name cell truncates from the head, so the distinguishing tail (drizzle/time) stays visible -- never .middle")
    func nameCellTruncatesFromHead() throws {
        let source = try contents("Sources/AstroUI/Features/Results/ResultsView.swift")
        #expect(!source.contains(".truncationMode(.middle)"))
        // Both the family and the variant name branches need the fix.
        let headOccurrences = source.components(separatedBy: ".truncationMode(.head)").count - 1
        #expect(headOccurrences >= 2)
    }

    @Test("The Kind column only renders a badge for variant (child) rows -- a family row's constant \"Original\" badge is gone")
    func kindBadgeOnlyOnVariants() throws {
        let source = try contents("Sources/AstroUI/Features/Results/ResultsView.swift")
        guard let columnRange = source.range(of: "TableColumn(\"Kind\")") else {
            Issue.record("Kind TableColumn not found")
            return
        }
        // The very next `variantBadge(` call after the column's own opening
        // must be conditioned on `.variant`, not called unconditionally for
        // every row (family rows included).
        let tail = source[columnRange.upperBound...]
        guard let badgeCallRange = tail.range(of: "variantBadge(") else {
            Issue.record("variantBadge( call not found after Kind column")
            return
        }
        let between = tail[tail.startIndex..<badgeCallRange.lowerBound]
        #expect(between.contains("case .variant"))
    }

    @Test("Size and Night columns are narrower than before, tightening the table to fit the default window width")
    func sizeAndNightColumnsAreNarrowed() throws {
        let source = try contents("Sources/AstroUI/Features/Results/ResultsView.swift")
        #expect(!source.contains(".width(min: 70, ideal: 90)"), "Size column should no longer use its old, wider bounds")
        #expect(!source.contains(".width(min: 90, ideal: 100)"), "Night column should no longer use its old, wider bounds")
    }
}
