import Foundation
import Testing
@testable import AstroMobileDomain

@Test func mobileChangesExposeExactlyTwoKinds() throws {
    #expect(MobileChangeKind.allCases == [.checklistCompletion, .noteRevision])
}
