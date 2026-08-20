import AstroApplication
import SwiftUI

/// The one place `ArchiveTaskKind` becomes a human title -- shared by
/// `ArchiveTaskCard` (its own headline), `ArchiveTaskDetailView` (its
/// `navigationTitle`), and `V2RootView`'s breadcrumb label, so the three
/// surfaces can never drift into two different names for the same kind of
/// finding. `titleText` stays plain `String` (needed verbatim by the
/// breadcrumb pipeline, which wraps at construction -- see
/// `BreadcrumbModel.crumbs`'s own doc comment for why); `title` wraps it in
/// `LocalizedStringKey` for direct use in `Text`/`.navigationTitle`.
///
/// `switch`-mapped, not table-driven, for the same localization-safety
/// reason `ArchiveTaskCard`'s own header used to document: a `switch`
/// returning a literal is invisible to `scripts/extract-localizable-strings.swift`,
/// so every case here is hand-added to `hu.lproj/Localizable.strings`
/// instead of relying on the extraction pass. All seven original cases
/// already had entries from `ArchiveTaskCard`'s own former `title` switch
/// (Task 8) -- moving the switch here changes nothing about which strings
/// need a translation. `.osMetadata` (W3-13) is the one case added since,
/// with its own hand-added entry.
enum ArchiveTaskPresentation {
    static func titleText(for kind: ArchiveTaskKind) -> String {
        switch kind {
        case .intermediateFiles: "Stacking leftovers"
        case .osMetadata: "Finder metadata files"
        case .duplicateContent: "Byte-identical copies"
        case .misplacedCalibration: "Calibration in the wrong folder"
        case .brokenNames: "Folder names that break scanning"
        case .corruption: "Checksum mismatch"
        case .unverified: "Could not be confirmed"
        case .auditNeverRun: "Not checked yet"
        }
    }

    static func title(for kind: ArchiveTaskKind) -> LocalizedStringKey {
        LocalizedStringKey(titleText(for: kind))
    }
}
