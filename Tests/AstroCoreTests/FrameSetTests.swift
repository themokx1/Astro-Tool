import Foundation
import Testing
@testable import AstroCore

/// Fixture-only `FrameSet` tests -- no disk access, just hand-built
/// `FileRecord`/`FITSMetaRecord` values, since `FrameSet.lightBuckets` is a
/// pure function over already-scanned rows.
private func lightFile(
    _ path: String,
    id: Int64,
    ext: String,
    target: String = "M31",
    sessionDate: String = "2026-01-01",
    inode: Int64? = nil,
    nlink: Int64? = nil
) -> FileRecord {
    FileRecord(
        id: id, path: path, size: 0, mtime: 0, ext: ext, kind: "fits", area: .sessions,
        target: target, sessionDate: sessionDate, role: .light, scannedAt: 0,
        inode: inode, nlink: nlink
    )
}

@Test func nonFrameExtensionIsCountedAsNonFrameNotUsable() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/l1.fit", id: 1, ext: "fit", inode: 1),
        lightFile("sessions/M31/2026-01-01/lights/sidecar.xmp", id: 2, ext: "xmp", inode: 2),
        lightFile("sessions/M31/2026-01-01/lights/report.html", id: 3, ext: "html", inode: 3),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())

    #expect(buckets.usable.map(\.id) == [1])
    #expect(buckets.rejected.isEmpty)
    #expect(buckets.nonFrameFileCount == 2)
    #expect(buckets.duplicateLinkCount == 0)
}

@Test func derivativeNamedFitFileIsCountedAsNonFrame() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/l1.fit", id: 1, ext: "fit", inode: 1),
        lightFile("sessions/M31/2026-01-01/lights/starless_stack.fit", id: 2, ext: "fit", inode: 2),
        lightFile("sessions/M31/2026-01-01/lights/starmask_stack.fit", id: 3, ext: "fit", inode: 3),
        lightFile("sessions/M31/2026-01-01/lights/M31_stacked.fit", id: 4, ext: "fit", inode: 4),
        lightFile("sessions/M31/2026-01-01/lights/autosave001.fit", id: 5, ext: "fit", inode: 5),
        lightFile("sessions/M31/2026-01-01/lights/result_final.fit", id: 6, ext: "fit", inode: 6),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())

    #expect(buckets.usable.map(\.id) == [1])
    #expect(buckets.nonFrameFileCount == 5)
}

@Test func asiairNumberedStackOutputsUnderLightsAreNotRawFrames() {
    let files = [
        lightFile("sessions/IC_1396/2026-08-08/lights/Light_Mu_Cephei_300.0s_0001.fit", id: 1, ext: "fit", inode: 1),
        lightFile("sessions/IC_1396/2026-08-08/lights/Stacked2_Mu_Cephei_300.0s.fit", id: 2, ext: "fit", inode: 2),
        lightFile("sessions/IC_1396/2026-08-08/lights/Stacked12_Mu_Cephei_300.0s.fit", id: 3, ext: "fit", inode: 3),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())

    #expect(buckets.usable.map(\.id) == [1])
    #expect(buckets.nonFrameFileCount == 2)
}

@Test func ordinaryFilenameStartingWithStackedWordButNoNumberIsNotMistakenForASIAirPrefix() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/StackedField_001.fit", id: 1, ext: "fit", inode: 1),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())

    #expect(buckets.usable.map(\.id) == [1])
    #expect(buckets.nonFrameFileCount == 0)
}

@Test func hardlinkedTriageCopiesDedupToOneCanonicalKeepingDirectLightsChild() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/l1.fit", id: 1, ext: "fit", inode: 100, nlink: 3),
        lightFile("sessions/M31/2026-01-01/lights/Review/l1.fit", id: 2, ext: "fit", inode: 100, nlink: 3),
        lightFile("sessions/M31/2026-01-01/lights/Stack/l1.fit", id: 3, ext: "fit", inode: 100, nlink: 3),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())

    #expect(buckets.usable.map(\.id) == [1])
    #expect(buckets.duplicateLinkCount == 2)
    #expect(buckets.nonFrameFileCount == 0)
}

@Test func onlyCopyUnderTriageSubdirIsKeptAsUsableWhenNoDirectLightsChildExists() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/Review/l1.fit", id: 1, ext: "fit", inode: 100, nlink: 2),
        lightFile("sessions/M31/2026-01-01/lights/Stack/l1.fit", id: 2, ext: "fit", inode: 100, nlink: 2),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())

    #expect(buckets.usable.count == 1)
    #expect(buckets.duplicateLinkCount == 1)
}

@Test func hardlinkUnderRejectDirLandsInRejectedBucketNotUsable() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/l1.fit", id: 1, ext: "fit", inode: 100, nlink: 2),
        lightFile("sessions/M31/2026-01-01/lights/Reject/blurry/l1.fit", id: 2, ext: "fit", inode: 100, nlink: 2),
    ]

    // The kept copy is the one directly under lights/ -- but it lands in
    // `rejected` only if THAT canonical copy's own path is under Reject/.
    // Here the canonical (direct lights/ child) is NOT under Reject, so it's
    // usable, and the Reject/ copy is just a dropped duplicate.
    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())
    #expect(buckets.usable.map(\.id) == [1])
    #expect(buckets.rejected.isEmpty)
    #expect(buckets.duplicateLinkCount == 1)
}

@Test func soleCopyOnlyUnderRejectLandsInRejectedBucket() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/Reject/blurry/l1.fit", id: 1, ext: "fit", inode: 100, nlink: 1),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())
    #expect(buckets.usable.isEmpty)
    #expect(buckets.rejected.map(\.id) == [1])
    #expect(buckets.duplicateLinkCount == 0)
}

@Test func archivedFrameRemainsVisibleButIsNeverUsable() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/archive/l1.fit", id: 1, ext: "fit", inode: 100),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())
    #expect(buckets.usable.isEmpty)
    #expect(buckets.rejected.map(\.id) == [1])
    #expect(FrameArchivePlanner.isArchived(files[0].path))
}

@Test func filesWithNoInodeDedupByTargetSessionDateObsAndExptimeFallbackKey() {
    let meta: [Int64: FITSMetaRecord] = [
        1: FITSMetaRecord(fileID: 1, exptime: 300, dateObs: "2026-04-18T04:36:24"),
        2: FITSMetaRecord(fileID: 2, exptime: 300, dateObs: "2026-04-18T04:36:24"),
    ]
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/l1.fit", id: 1, ext: "fit", inode: nil),
        lightFile("sessions/M31/2026-01-01/lights/Review/l1.fit", id: 2, ext: "fit", inode: nil),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: meta, config: AstroConfig())
    #expect(buckets.usable.count == 1)
    #expect(buckets.duplicateLinkCount == 1)
}

@Test func differentExptimeWithNoInodeIsNotDedupedAsFallback() {
    let meta: [Int64: FITSMetaRecord] = [
        1: FITSMetaRecord(fileID: 1, exptime: 300, dateObs: "2026-04-18T04:36:24"),
        2: FITSMetaRecord(fileID: 2, exptime: 60, dateObs: "2026-04-18T04:36:24"),
    ]
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/l1.fit", id: 1, ext: "fit", inode: nil),
        lightFile("sessions/M31/2026-01-01/lights/l2.fit", id: 2, ext: "fit", inode: nil),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: meta, config: AstroConfig())
    #expect(buckets.usable.count == 2)
    #expect(buckets.duplicateLinkCount == 0)
}

@Test func cr3AndTifWithMatchingNormalizedDateObsDedupKeepingRaw() {
    let meta: [Int64: FITSMetaRecord] = [
        1: FITSMetaRecord(fileID: 1, dateObs: "2026:04:18 04:36:24"),
        2: FITSMetaRecord(fileID: 2, dateObs: "2026-04-18T04:36:24"),
    ]
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/IMG_0001.cr3", id: 1, ext: "cr3", inode: 10),
        lightFile("sessions/M31/2026-01-01/lights/IMG_0001_conv.tif", id: 2, ext: "tif", inode: 20),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: meta, config: AstroConfig())
    #expect(buckets.usable.map(\.ext) == ["cr3"])
    #expect(buckets.duplicateLinkCount == 1)
}

@Test func cr3AndTifWithSameBasenameStemDedupWhenNoDateObs() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/IMG_0002.cr3", id: 1, ext: "cr3", inode: 11),
        lightFile("sessions/M31/2026-01-01/lights/IMG_0002.tif", id: 2, ext: "tif", inode: 21),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())
    #expect(buckets.usable.map(\.ext) == ["cr3"])
    #expect(buckets.duplicateLinkCount == 1)
}

@Test func unrelatedCr3AndTifAreNotDeduped() {
    let files = [
        lightFile("sessions/M31/2026-01-01/lights/IMG_0003.cr3", id: 1, ext: "cr3", inode: 12),
        lightFile("sessions/M31/2026-01-01/lights/totally_different.tif", id: 2, ext: "tif", inode: 22),
    ]

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())
    #expect(Set(buckets.usable.map(\.id)) == Set([1, 2]))
    #expect(buckets.duplicateLinkCount == 0)
}

@Test func distinctRealFramesWithDistinctInodesAreAllUsable() {
    let files = (1...5).map { i in
        lightFile("sessions/M31/2026-01-01/lights/l\(i).fit", id: Int64(i), ext: "fit", inode: Int64(i))
    }

    let buckets = FrameSet.lightBuckets(files: files, meta: [:], config: AstroConfig())
    #expect(buckets.usable.count == 5)
    #expect(buckets.duplicateLinkCount == 0)
    #expect(buckets.nonFrameFileCount == 0)
}

@Test func emptyInputYieldsEmptyBuckets() {
    let buckets = FrameSet.lightBuckets(files: [], meta: [:], config: AstroConfig())
    #expect(buckets.usable.isEmpty)
    #expect(buckets.rejected.isEmpty)
    #expect(buckets.duplicateLinkCount == 0)
    #expect(buckets.nonFrameFileCount == 0)
}
