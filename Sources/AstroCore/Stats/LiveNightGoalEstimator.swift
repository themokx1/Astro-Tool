import Foundation

/// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): the "hátralévő
/// keretek × (medián expozíció + medián kereszti szünet)" ETA arithmetic the
/// spec calls for -- genuinely new logic. `GoalTag` (this same directory)
/// only ever parsed the goal itself into seconds; nothing in this codebase
/// projected a finish time from a still-running session's own observed
/// pace before this. Pure arithmetic over already-known facts (the
/// exposure length and timestamp of every frame captured so far tonight,
/// plus the goal in seconds) -- no I/O, no FITS access -- so every case is
/// a plain, exhaustively testable input/output pair.
public enum LiveNightGoalEstimator {
    public struct Estimate: Equatable, Sendable {
        public let integratedSeconds: Double
        public let goalSeconds: Double
        /// `integratedSeconds / goalSeconds` -- CAN exceed 1.0 once the
        /// goal is met; callers clamp for a progress bar, this type never
        /// does (clamping here would hide "146% of goal" from a caller that
        /// wants to say so honestly).
        public let progressFraction: Double
        /// `0` once the goal is already met. `nil` when the pace (the
        /// median exposure length observed so far) is unknown or zero --
        /// "can't project a finish time," never a bogus one.
        public let remainingFrameCount: Int?
        /// `nil` under the same "can't project" condition as
        /// `remainingFrameCount`; exactly `now` when the goal is already
        /// met (there is nothing left to wait for).
        public let etaDate: Date?

        public init(
            integratedSeconds: Double,
            goalSeconds: Double,
            progressFraction: Double,
            remainingFrameCount: Int?,
            etaDate: Date?
        ) {
            self.integratedSeconds = integratedSeconds
            self.goalSeconds = goalSeconds
            self.progressFraction = progressFraction
            self.remainingFrameCount = remainingFrameCount
            self.etaDate = etaDate
        }
    }

    /// - Parameters:
    ///   - exposureSeconds: one entry per light frame captured tonight
    ///     whose exposure length is actually known (FITS `EXPTIME`, or a
    ///     CR3's own Exif `ExposureTime` -- see `LiveNightSessionModel`'s
    ///     own doc comment for why a frame with an UNKNOWN length is
    ///     omitted here entirely rather than guessed at). Any order.
    ///   - timestamps: the capture instant of each of those same frames,
    ///     same count as `exposureSeconds` but not required to already be
    ///     in order -- this sorts them itself before taking gaps.
    ///   - goalSeconds: the target integration time, already resolved by
    ///     the caller (this type never reads `GoalTag`/project state
    ///     itself).
    ///   - now: injected rather than `Date()` so this stays a pure,
    ///     deterministic function for tests.
    /// - Returns: `nil` when there is nothing honest to estimate --
    ///   `goalSeconds <= 0`, or no frames with a known exposure length yet.
    public static func estimate(
        exposureSeconds: [Double],
        timestamps: [Date],
        goalSeconds: Double,
        now: Date
    ) -> Estimate? {
        guard goalSeconds > 0, !exposureSeconds.isEmpty, exposureSeconds.count == timestamps.count else { return nil }

        let integrated = exposureSeconds.reduce(0, +)
        let progress = integrated / goalSeconds

        guard integrated < goalSeconds else {
            return Estimate(
                integratedSeconds: integrated, goalSeconds: goalSeconds, progressFraction: progress,
                remainingFrameCount: 0, etaDate: now
            )
        }

        let medianExposure = median(exposureSeconds)
        guard medianExposure > 0 else {
            return Estimate(
                integratedSeconds: integrated, goalSeconds: goalSeconds, progressFraction: progress,
                remainingFrameCount: nil, etaDate: nil
            )
        }

        let remainingSeconds = goalSeconds - integrated
        let remainingFrames = Int((remainingSeconds / medianExposure).rounded(.up))

        // The "kereszti szünet" (dead time) the spec's own ETA formula
        // wants is the gap BETWEEN one frame's exposure ending and the
        // next one's starting -- NOT the raw difference between two
        // consecutive frames' own start times, which already CONTAINS the
        // first frame's exposure length. Pairing each exposure with its own
        // timestamp before sorting (rather than sorting `timestamps` alone)
        // keeps that pairing intact even when the caller's two arrays
        // weren't already in chronological order.
        let pairs = zip(exposureSeconds, timestamps).sorted { $0.1 < $1.1 }
        var deadTimes: [Double] = []
        if pairs.count > 1 {
            for i in 0..<(pairs.count - 1) {
                let period = pairs[i + 1].1.timeIntervalSince(pairs[i].1)
                let deadTime = period - pairs[i].0
                if deadTime >= 0 { deadTimes.append(deadTime) }
            }
        }
        let medianDeadTime = deadTimes.isEmpty ? 0 : median(deadTimes)
        let perFrameSeconds = medianExposure + medianDeadTime
        let eta = now.addingTimeInterval(Double(remainingFrames) * perFrameSeconds)

        return Estimate(
            integratedSeconds: integrated, goalSeconds: goalSeconds, progressFraction: progress,
            remainingFrameCount: remainingFrames, etaDate: eta
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
