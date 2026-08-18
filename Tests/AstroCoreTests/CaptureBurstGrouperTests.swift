import Foundation
import Testing
@testable import AstroCore

/// Builds a minimal `DiscoveredCaptureFile` for grouping tests -- only
/// `captureInstant` (the grouper's sort/split key) and whatever else a given
/// test cares about need to vary; everything else gets an innocuous default.
private func makeFile(
    name: String,
    ext: String = "fits",
    kind: String = "fits",
    sizeBytes: Int64 = 1_000,
    proposedRole: FrameRole? = nil,
    instant: Date,
    exposureSeconds: Double? = nil,
    iso: Int? = nil,
    apertureFNumber: Double? = nil
) -> DiscoveredCaptureFile {
    DiscoveredCaptureFile(
        sourceURL: URL(fileURLWithPath: "/tmp/\(name)"),
        relativeSourcePath: name,
        fileName: name,
        ext: ext,
        kind: kind,
        sizeBytes: sizeBytes,
        proposedRole: proposedRole,
        captureDate: nil,
        captureDateSource: nil,
        captureInstant: instant,
        exposureSeconds: exposureSeconds,
        iso: iso,
        apertureFNumber: apertureFNumber
    )
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("CaptureBurstGrouper")
struct CaptureBurstGrouperTests {
    @Test("An empty input produces no groups")
    func emptyInputProducesNoGroups() {
        #expect(CaptureBurstGrouper.group([]).isEmpty)
    }

    @Test("A single file produces exactly one single-file group")
    func singleFileProducesOneGroup() {
        let file = makeFile(name: "a.fits", instant: epoch)
        let groups = CaptureBurstGrouper.group([file])
        #expect(groups.count == 1)
        #expect(groups[0].fileCount == 1)
        #expect(groups[0].files == [file])
    }

    @Test("A steady cadence with no large gap stays one group")
    func steadyCadenceStaysOneGroup() {
        // 20 frames, 30s apart -- a typical short-exposure calibration run.
        let files = (0..<20).map { index in
            makeFile(name: "f\(index).fits", instant: epoch.addingTimeInterval(Double(index) * 30))
        }
        let groups = CaptureBurstGrouper.group(files)
        #expect(groups.count == 1)
        #expect(groups[0].fileCount == 20)
    }

    @Test("A 300-second light cadence must not split -- the floor stays generous")
    func threeHundredSecondCadenceDoesNotSplit() {
        // 12 lights, 300s (5 min) apart -- the exact case the brief calls
        // out by name: "a 300s light cadence must not split".
        let files = (0..<12).map { index in
            makeFile(name: "light_\(index).cr3", ext: "cr3", kind: "raw", instant: epoch.addingTimeInterval(Double(index) * 300))
        }
        let groups = CaptureBurstGrouper.group(files)
        #expect(groups.count == 1, "a steady 300s cadence sits under the 900s floor and must never split")
        #expect(groups[0].fileCount == 12)
    }

    @Test("A large gap between two runs splits into two groups")
    func largeGapSplitsIntoTwoGroups() {
        // 10 lights at 30s cadence, then a 2-hour gap, then 10 flats at 5s
        // cadence -- the classic "lights, then repositioned for flats" shape.
        var files: [DiscoveredCaptureFile] = (0..<10).map { index in
            makeFile(name: "light_\(index).fits", instant: epoch.addingTimeInterval(Double(index) * 30))
        }
        let flatStart = epoch.addingTimeInterval(9 * 30 + 2 * 3600)
        files += (0..<10).map { index in
            makeFile(name: "flat_\(index).fits", instant: flatStart.addingTimeInterval(Double(index) * 5))
        }

        let groups = CaptureBurstGrouper.group(files)
        #expect(groups.count == 2)
        #expect(groups[0].fileCount == 10)
        #expect(groups[1].fileCount == 10)
        #expect(groups[0].files.allSatisfy { $0.fileName.hasPrefix("light_") })
        #expect(groups[1].files.allSatisfy { $0.fileName.hasPrefix("flat_") })
    }

    @Test("Three separate runs (lights, flats, darks) produce three groups")
    func threeRunsProduceThreeGroups() {
        var files: [DiscoveredCaptureFile] = []
        var cursor = epoch
        for run in 0..<3 {
            for index in 0..<8 {
                files.append(makeFile(name: "run\(run)_\(index).fits", instant: cursor.addingTimeInterval(Double(index) * 20)))
            }
            cursor = cursor.addingTimeInterval(8 * 20 + 3600) // a full hour between runs
        }
        let groups = CaptureBurstGrouper.group(files)
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.fileCount == 8 })
    }

    @Test("Files with mixed exposure lengths but adjacent timestamps still group together")
    func mixedExposuresWithinOneIntervalStillGroupTogether() {
        // The rule is purely time-based: a stray different-exposure frame
        // shot in the middle of a run does not, on its own, split the group.
        let files = [
            makeFile(name: "a.cr3", ext: "cr3", kind: "raw", instant: epoch, exposureSeconds: 300),
            makeFile(name: "b.cr3", ext: "cr3", kind: "raw", instant: epoch.addingTimeInterval(60), exposureSeconds: 0.001),
            makeFile(name: "c.cr3", ext: "cr3", kind: "raw", instant: epoch.addingTimeInterval(120), exposureSeconds: 300),
        ]
        let groups = CaptureBurstGrouper.group(files)
        #expect(groups.count == 1, "grouping never looks at exposure length, only capture time")
        #expect(groups[0].fileCount == 3)
    }

    @Test("Unsorted input groups identically to sorted input")
    func unsortedInputGroupsTheSameAsSorted() {
        let sorted = (0..<6).map { index in
            makeFile(name: "f\(index).fits", instant: epoch.addingTimeInterval(Double(index) * 30))
        }
        let shuffled = [sorted[3], sorted[0], sorted[5], sorted[1], sorted[4], sorted[2]]
        let groupsFromSorted = CaptureBurstGrouper.group(sorted)
        let groupsFromShuffled = CaptureBurstGrouper.group(shuffled)
        #expect(groupsFromSorted.map { $0.files.map(\.fileName) } == groupsFromShuffled.map { $0.files.map(\.fileName) })
    }

    @Test("A jittery but still-adapting cadence does not falsely split")
    func jitteryCadenceAdaptsAndDoesNotSplit() {
        // Gaps: 5, 6, 5, 40, 5, 5 -- one slow write (40s, well under the 900s
        // floor and also under 4x even a modest running median) should not
        // be mistaken for a session boundary.
        let gaps: [Double] = [5, 6, 5, 40, 5, 5]
        var instant = epoch
        var files = [makeFile(name: "f0.fits", instant: instant)]
        for (index, gap) in gaps.enumerated() {
            instant = instant.addingTimeInterval(gap)
            files.append(makeFile(name: "f\(index + 1).fits", instant: instant))
        }
        let groups = CaptureBurstGrouper.group(files)
        #expect(groups.count == 1)
    }

    @Test("agreedProposedRole is set only when every FITS file in the group agrees")
    func agreedProposedRoleRequiresUnanimity() {
        let agreeing = [
            makeFile(name: "a.fits", proposedRole: .flat, instant: epoch),
            makeFile(name: "b.fits", proposedRole: .flat, instant: epoch.addingTimeInterval(5)),
        ]
        let group = CaptureFileGroup(files: agreeing)
        #expect(group.agreedProposedRole == .flat)

        let disagreeing = [
            makeFile(name: "a.fits", proposedRole: .flat, instant: epoch),
            makeFile(name: "b.fits", proposedRole: .dark, instant: epoch.addingTimeInterval(5)),
        ]
        #expect(CaptureFileGroup(files: disagreeing).agreedProposedRole == nil)

        let oneUnclassified = [
            makeFile(name: "a.fits", proposedRole: .flat, instant: epoch),
            makeFile(name: "b.cr3", ext: "cr3", kind: "raw", proposedRole: nil, instant: epoch.addingTimeInterval(5)),
        ]
        #expect(CaptureFileGroup(files: oneUnclassified).agreedProposedRole == nil)
    }

    @Test("representativeFile is the middle file by capture order")
    func representativeFileIsTheMiddleFile() {
        let files = (0..<5).map { index in
            makeFile(name: "f\(index).fits", instant: epoch.addingTimeInterval(Double(index) * 10))
        }
        let group = CaptureFileGroup(files: files)
        #expect(group.representativeFile?.fileName == "f2.fits")
    }

    @Test("commonExtension is nil when a group mixes file kinds")
    func commonExtensionIsNilWhenMixed() {
        let files = [
            makeFile(name: "a.fits", instant: epoch),
            makeFile(name: "b.cr3", ext: "cr3", kind: "raw", instant: epoch.addingTimeInterval(5)),
        ]
        let group = CaptureFileGroup(files: files)
        #expect(group.commonExtension == nil)
    }

    @Test("totalBytes and fileIDs are the sum/set of the member files")
    func totalBytesAndFileIDs() {
        let files = [
            makeFile(name: "a.fits", sizeBytes: 100, instant: epoch),
            makeFile(name: "b.fits", sizeBytes: 250, instant: epoch.addingTimeInterval(5)),
        ]
        let group = CaptureFileGroup(files: files)
        #expect(group.totalBytes == 350)
        #expect(group.fileIDs == Set(files.map(\.id)))
    }
}

@Suite("CaptureGroupExposureSummary")
struct CaptureGroupExposureSummaryTests {
    @Test("nil when no file in the group has any Exif value")
    func nilWhenNoExifAtAll() {
        let files = [makeFile(name: "a.fits", instant: epoch)]
        #expect(CaptureGroupExposureSummary(files: files) == nil)
    }

    @Test("medianExposureSeconds ignores files with no exposure value")
    func medianIgnoresMissingValues() throws {
        let files = [
            makeFile(name: "a.cr3", ext: "cr3", kind: "raw", instant: epoch, exposureSeconds: 300),
            makeFile(name: "b.cr3", ext: "cr3", kind: "raw", instant: epoch.addingTimeInterval(5), exposureSeconds: nil),
            makeFile(name: "c.cr3", ext: "cr3", kind: "raw", instant: epoch.addingTimeInterval(10), exposureSeconds: 300),
        ]
        let summary = try #require(CaptureGroupExposureSummary(files: files))
        #expect(summary.medianExposureSeconds == 300)
    }

    @Test("mostCommonISO picks the most frequent value")
    func mostCommonISOPicksTheMode() throws {
        let files = [
            makeFile(name: "a.cr3", ext: "cr3", kind: "raw", instant: epoch, iso: 800),
            makeFile(name: "b.cr3", ext: "cr3", kind: "raw", instant: epoch.addingTimeInterval(5), iso: 800),
            makeFile(name: "c.cr3", ext: "cr3", kind: "raw", instant: epoch.addingTimeInterval(10), iso: 1600),
        ]
        let summary = try #require(CaptureGroupExposureSummary(files: files))
        #expect(summary.mostCommonISO == 800)
    }
}

@Suite("CaptureExposureRoleHint")
struct CaptureExposureRoleHintTests {
    @Test("nil for a nil median")
    func nilForNilMedian() {
        #expect(CaptureExposureRoleHint.suggest(medianExposureSeconds: nil) == nil)
    }

    @Test("bias for a sub-10ms median exposure")
    func biasForSubTenMillisecondExposure() {
        #expect(CaptureExposureRoleHint.suggest(medianExposureSeconds: 0.0002) == .bias)
        #expect(CaptureExposureRoleHint.suggest(medianExposureSeconds: 0.005) == .bias)
    }

    @Test("flat for an exposure between the bias and flat ceilings")
    func flatForShortButNotSubMillisecondExposure() {
        #expect(CaptureExposureRoleHint.suggest(medianExposureSeconds: 0.02) == .flat)
        #expect(CaptureExposureRoleHint.suggest(medianExposureSeconds: 2.0) == .flat)
    }

    @Test("nil for a long exposure -- light vs dark is never guessed from exposure alone")
    func nilForLongExposure() {
        #expect(CaptureExposureRoleHint.suggest(medianExposureSeconds: 30) == nil)
        #expect(CaptureExposureRoleHint.suggest(medianExposureSeconds: 300) == nil)
    }

    @Test("exact boundary values fall into the shorter bucket")
    func boundaryValues() {
        #expect(CaptureExposureRoleHint.suggest(medianExposureSeconds: CaptureExposureRoleHint.biasMaxSeconds) == .flat)
        #expect(CaptureExposureRoleHint.suggest(medianExposureSeconds: CaptureExposureRoleHint.flatMaxSeconds) == nil)
    }
}
