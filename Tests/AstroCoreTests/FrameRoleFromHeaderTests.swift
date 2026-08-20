import Testing
@testable import AstroCore

@Test func frameRoleFromHeaderRecognizesAllFourFrameKindsCaseInsensitively() {
    #expect(FrameRoleFromHeader.role(fromImagetyp: "Light Frame") == .light)
    #expect(FrameRoleFromHeader.role(fromImagetyp: "FLAT") == .flat)
    #expect(FrameRoleFromHeader.role(fromImagetyp: "Dark Frame") == .dark)
    #expect(FrameRoleFromHeader.role(fromImagetyp: "bias frame") == .bias)
}

@Test func frameRoleFromHeaderReturnsNilForAnUnrecognizedValue() {
    #expect(FrameRoleFromHeader.role(fromImagetyp: "Master Flat") == .flat, "still matches on substring, same as the scanner's own original behavior")
    #expect(FrameRoleFromHeader.role(fromImagetyp: "Snapshot") == nil)
    #expect(FrameRoleFromHeader.role(fromImagetyp: "") == nil)
}
