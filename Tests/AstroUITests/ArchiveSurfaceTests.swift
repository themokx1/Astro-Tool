@testable import AstroUI
import AstroApplication
import Testing

struct ArchiveStripLayoutTests {
    @Test("Slice fractions sum to one")
    func fractionsSumToOne() {
        let layout = ArchiveStripLayout(slices: [
            .init(archiveClass: .light, fileCount: 1, bytes: 300),
            .init(archiveClass: .stack, fileCount: 1, bytes: 600),
            .init(archiveClass: .calibration, fileCount: 1, bytes: 100),
        ])
        #expect(abs(layout.segments.reduce(0) { $0 + $1.fraction } - 1.0) < 0.0001)
        #expect(layout.segments.map(\.archiveClass) == [.light, .stack, .calibration])
    }

    @Test("Slices under half a percent merge into one residual segment")
    func tinySlicesMerge() {
        let layout = ArchiveStripLayout(slices: [
            .init(archiveClass: .light, fileCount: 1, bytes: 99_800),
            .init(archiveClass: .stack, fileCount: 1, bytes: 100),
            .init(archiveClass: .calibration, fileCount: 1, bytes: 100),
        ])
        #expect(layout.segments.count == 2, "the two 0.1% slices collapse into one residual")
        #expect(layout.segments.last?.isResidual == true)
        #expect(abs(layout.segments.reduce(0) { $0 + $1.fraction } - 1.0) < 0.0001)
    }

    @Test("An empty archive produces no segments and never divides by zero")
    func emptyArchiveHasNoSegments() {
        #expect(ArchiveStripLayout(slices: []).segments.isEmpty)
        #expect(ArchiveStripLayout(slices: [.init(archiveClass: .light, fileCount: 0, bytes: 0)]).segments.isEmpty)
    }
}
