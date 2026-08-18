import Testing
@testable import AstroCore

/// W7-C: `FocalLengthBucketing` is the one engine `EquipmentProfile.fingerprint`,
/// `ScanWorkflowMaterializer`'s series setup descriptor, and `ExposureAdvisor`
/// all share to canonicalize ASI-Air-style plate-solve `FOCALLEN` jitter.
/// These fixtures are drawn straight from the owner's real ASI2600MC Pro
/// library (`index.sqlite`) -- see `FocalLengthBucketing`'s doc comment for
/// the full distribution and the rule's justification against it.
@Suite("FocalLengthBucketing")
struct FocalLengthBucketingTests {
    @Test("The confirmed one-rig jitter (255/256/261/262 mm) collapses to a single bucket")
    func mergesConfirmedSameRigJitter() {
        let table = FocalLengthBucketing.clusters([255.0, 256.0, 261.0, 262.0])
        let canonical = Set([255.0, 256.0, 261.0, 262.0].map {
            FocalLengthBucketing.canonicalize($0, buckets: table)
        })
        #expect(canonical.count == 1)
    }

    @Test("A tighter jitter run (133/134/135 mm) also collapses to a single bucket")
    func mergesTighterJitterAlreadyInsideOneFiveMMBucket() {
        let table = FocalLengthBucketing.clusters([133.0, 134.0, 135.0])
        let canonical = Set([133.0, 134.0, 135.0].map {
            FocalLengthBucketing.canonicalize($0, buckets: table)
        })
        #expect(canonical.count == 1)
    }

    @Test("Two genuinely different optics (100 mm vs 135 mm) never merge")
    func keepsDistinctOpticsApart() {
        let table = FocalLengthBucketing.clusters([101.8, 102.0, 133.0, 134.0, 135.0])
        let short = FocalLengthBucketing.canonicalize(102.0, buckets: table)
        let long = FocalLengthBucketing.canonicalize(134.0, buckets: table)
        #expect(short != long)
    }

    @Test("A real gap in the data (262 mm to 292 mm, 11%+) is never bridged")
    func doesNotChainAcrossARealGapInTheData() {
        // The owner's library has ZERO frames between 262 and 292 mm -- the
        // rule must not merge these two runs just because each one
        // internally clusters to a single bucket close to 250 mm's 2%
        // threshold.
        let table = FocalLengthBucketing.clusters([255.0, 256.0, 261.0, 262.0, 292.0, 293.0, 300.0, 304.0])
        let nearRig = FocalLengthBucketing.canonicalize(261.0, buckets: table)
        let farRig = FocalLengthBucketing.canonicalize(293.0, buckets: table)
        #expect(nearRig != farRig)
    }

    @Test("A lone value with no neighbors stays exactly at its own rounded-to-5 bucket")
    func isolatedValueRoundsToNearestFive() {
        let table = FocalLengthBucketing.clusters([179.0])
        #expect(FocalLengthBucketing.canonicalize(179.0, buckets: table) == 180.0)
    }

    @Test("canonicalize falls back to plain rounding when the camera has no bucket table")
    func canonicalizeFallsBackWhenBucketsEmpty() {
        #expect(FocalLengthBucketing.canonicalize(301.6, buckets: [:]) == 300.0)
    }

    @Test("clusters is empty for empty input")
    func clustersEmptyForEmptyInput() {
        #expect(FocalLengthBucketing.clusters([]).isEmpty)
    }
}
