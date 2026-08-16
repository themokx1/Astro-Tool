@testable import AstroApplication
import Testing

struct ArchiveClassTests {
    @Test("Every scanner role maps to exactly one archive class")
    func rolesMapToClasses() {
        #expect(ArchiveClass(role: "light") == .light)
        #expect(ArchiveClass(role: "flat") == .calibration)
        #expect(ArchiveClass(role: "dark") == .calibration)
        #expect(ArchiveClass(role: "bias") == .calibration)
        #expect(ArchiveClass(role: "stack") == .stack)
        #expect(ArchiveClass(role: "processed") == .processed)
        #expect(ArchiveClass(role: "other") == .unclassified)
    }

    @Test("An unknown or empty role falls back to unclassified, never crashing")
    func unknownRoleFallsBack() {
        #expect(ArchiveClass(role: "somethingNew") == .unclassified)
        #expect(ArchiveClass(role: "") == .unclassified)
        #expect(ArchiveClass(role: "LIGHT") == .light, "role matching is case-insensitive")
    }

    @Test("The display order is stable and puts collected data first")
    func displayOrderIsStable() {
        #expect(ArchiveClass.displayOrder == [.light, .stack, .processed, .calibration, .unclassified])
    }
}
