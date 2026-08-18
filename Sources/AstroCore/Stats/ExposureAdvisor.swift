import Foundation

/// One target's sub-exposure-length recommendation + relative-SNR guidance,
/// built entirely from MEASURED data already on record: `SensorProfile`'s
/// bias level/read noise/EGAIN (`astrotool sensor --measure`), and
/// `ratings.bg_00/01/10/11` per-Bayer background medians (R7-B1, needs
/// `astrotool rate` to have run since then). Every numeric field here is
/// exclusive with `notAvailableReason` -- see `ExposureAdvisor.advise`'s doc
/// comment for exactly which fields stay populated even when the sub-length
/// section is `n/a` (the relative-SNR section needs no sky data at all).
public struct ExposureAdvice: Codable, Sendable {
    public var target: String
    /// The session date the sub-length section's numbers were computed
    /// from -- the most recent session (among the target's DOMINANT setup
    /// fingerprint's usable frames) that has at least one rated frame on
    /// file. `nil` when no such session was found.
    public var sessionDate: String?
    public var camera: String?
    public var gain: Double?
    /// Median exposure length (seconds) among the chosen session's rated
    /// frames -- "what you're actually shooting right now".
    public var currentSubSeconds: Double?
    /// "R"/"G"/"B" -- the READ-NOISE-LIMITED channel: the one with the
    /// LOWEST measured sky electron rate among the channels that have data.
    /// That channel's own (low) sky signal is what actually gates the
    /// optimal sub length -- a brighter channel already drowns read noise in
    /// its own shot noise at a shorter sub than this one needs.
    public var weakestChannel: String?
    /// The weakest channel's measured sky rate, in e⁻/s/px: `max(0,
    /// (median_ADU − bias_level_adu) × egain / exptime)`.
    public var skyRateEPerSPx: Double?
    /// The sensor's measured read noise (e⁻), from `SensorProfile`.
    public var readNoiseE: Double?
    /// Uncapped `t = R² / (B × ((1+C)² − 1))`, `C =
    /// config.expose.noiseContributionC` (default 0.05 → `≈9.76·R²/B`).
    public var optimalSubSeconds: Double?
    /// `optimalSubSeconds` after the `maxSubSeconds`/saturation caps --
    /// `capReason` says which (if either) actually bound.
    public var recommendedSubSeconds: Double?
    /// The same formula with a FIXED `C = 0.10` (`≈4.76·R²/B`) -- the
    /// "shorter subs, small extra read-noise cost" alternative. Always
    /// computed independent of the configured `noiseContributionC`, so a
    /// caller can show both trade-off points side by side.
    public var recommendedSubSecondsC10: Double?
    /// Read noise's SHARE of the current sub's total per-sub noise (stddev
    /// terms), as a percent: `(1 − √(B·t / (R² + B·t))) × 100`. This is a
    /// share, not a "the frame's noise is X% higher" figure -- the two only
    /// coincide in the limit of a vanishing share. Writing `s` for this
    /// share (as a fraction, not percent), the actual increase in total
    /// per-sub noise over pure sky shot noise alone is `s / (1 − s)`: an 8%
    /// share is an 0.08/0.92 ≈ 8.7% actual increase, and the gap between
    /// the two widens as read noise's contribution grows. Displayed as-is
    /// ("8%") rather than converted to the increase figure -- share is what
    /// the sub-length trade-off (`optimalSubSeconds`'s own `C` parameter)
    /// is actually defined in terms of.
    public var currentReadNoiseSharePercent: Double?
    /// Same formula, evaluated at `recommendedSubSeconds` instead of the
    /// current sub length.
    public var recommendedReadNoiseSharePercent: Double?
    /// `"maxSubSeconds"` | `"szaturáció"` | `nil` (no cap needed --
    /// `recommendedSubSeconds == optimalSubSeconds`).
    public var capReason: String?
    /// Total usable integration (seconds) across ALL of the target's
    /// sessions, restricted to frames matching `setupDescriptor`'s dominant
    /// setup fingerprint -- mixing integration time across an equipment
    /// change would misrepresent the relative-SNR math below, which assumes
    /// every second came from the same optical train.
    public var totalUsableSeconds: Double
    /// Hours of ADDITIONAL integration (at the current setup) needed for a
    /// further +10% relative SNR: `0.21 × (totalUsableSeconds / 3600)` --
    /// solves `√((T+X)/T) = 1.10` for `X` (since `(1.10)² − 1 = 0.21`).
    public var snrPlus10PercentHours: Double
    /// The relative-SNR multiplier from adding exactly 3 more hours to
    /// `totalUsableSeconds`: `√((T + 3h) / T)`. `nil` when `totalUsableSeconds
    /// <= 0` (nothing to take a ratio against).
    public var snrPlus3hMultiplier: Double?
    /// The dominant `SetupFingerprint.descriptor` the SNR section (and, when
    /// available, the sub-length section) was computed against.
    public var setupDescriptor: String?
    /// Hungarian sentences, ready to display as-is -- see
    /// `ExposureAdvisor.advise`'s doc comment for the exact phrasing rules.
    public var advice: [String]
    /// Set (exclusive with the sub-length-section numeric fields above --
    /// `weakestChannel` through `recommendedReadNoiseSharePercent`, plus
    /// `capReason`) when the sub-length recommendation itself can't be
    /// computed. The relative-SNR fields (`totalUsableSeconds` and later)
    /// stay populated regardless, since that section needs no sky data at
    /// all.
    public var notAvailableReason: String?

    public init(
        target: String,
        sessionDate: String? = nil,
        camera: String? = nil,
        gain: Double? = nil,
        currentSubSeconds: Double? = nil,
        weakestChannel: String? = nil,
        skyRateEPerSPx: Double? = nil,
        readNoiseE: Double? = nil,
        optimalSubSeconds: Double? = nil,
        recommendedSubSeconds: Double? = nil,
        recommendedSubSecondsC10: Double? = nil,
        currentReadNoiseSharePercent: Double? = nil,
        recommendedReadNoiseSharePercent: Double? = nil,
        capReason: String? = nil,
        totalUsableSeconds: Double,
        snrPlus10PercentHours: Double,
        snrPlus3hMultiplier: Double? = nil,
        setupDescriptor: String? = nil,
        advice: [String] = [],
        notAvailableReason: String? = nil
    ) {
        self.target = target
        self.sessionDate = sessionDate
        self.camera = camera
        self.gain = gain
        self.currentSubSeconds = currentSubSeconds
        self.weakestChannel = weakestChannel
        self.skyRateEPerSPx = skyRateEPerSPx
        self.readNoiseE = readNoiseE
        self.optimalSubSeconds = optimalSubSeconds
        self.recommendedSubSeconds = recommendedSubSeconds
        self.recommendedSubSecondsC10 = recommendedSubSecondsC10
        self.currentReadNoiseSharePercent = currentReadNoiseSharePercent
        self.recommendedReadNoiseSharePercent = recommendedReadNoiseSharePercent
        self.capReason = capReason
        self.totalUsableSeconds = totalUsableSeconds
        self.snrPlus10PercentHours = snrPlus10PercentHours
        self.snrPlus3hMultiplier = snrPlus3hMultiplier
        self.setupDescriptor = setupDescriptor
        self.advice = advice
        self.notAvailableReason = notAvailableReason
    }
}

/// Computes `ExposureAdvice` from measured data already on record -- never
/// guesses a number it can't derive from `SensorProfile`/`ratings`. See
/// `advise(target:db:config:)`'s doc comment for the exact refusal
/// conditions and phrasing rules.
public enum ExposureAdvisor {
    /// Fixed "shorter subs, small extra read-noise cost" alternative C --
    /// independent of `config.expose.noiseContributionC` so a caller can
    /// always compare both trade-off points.
    private static let alternativeC = 0.10
    /// A session whose median `saturatedFraction` (at the CURRENT sub
    /// length) exceeds this is already clipping meaningfully -- lengthening
    /// the sub further would only make it worse, so this caps
    /// `recommendedSubSeconds` at the current length regardless of the
    /// theoretical optimum.
    private static let saturationFractionThreshold = 0.001
    /// The current sub is considered "already fine" (no need to change
    /// anything) once it reaches at least this fraction of the recommended
    /// length.
    private static let readyShareFraction = 0.9
    private static let secondsPerHour = 3600.0

    // MARK: - Public API

    /// One target's exposure advice. Never throws for "no data" conditions
    /// -- those come back as `notAvailableReason` (with the relative-SNR
    /// fields still populated whenever possible; see `ExposureAdvice`'s doc
    /// comment). Throws only on an actual `Database` I/O failure.
    public static func advise(target: String, db: Database, config: AstroConfig) throws -> ExposureAdvice {
        let allFiles = try db.allFiles(includeMissing: false)
        let sessionLights = allFiles.filter { $0.target == target && $0.area == .sessions && $0.role == .light }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in sessionLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: sessionLights, meta: metaByFileID, config: config)
        guard !buckets.usable.isEmpty else {
            return naReply(target: target, reason: "nincs használható light-keret ehhez a célponthoz", totalUsableSeconds: 0)
        }

        let counts = EquipmentProfile.fingerprintCounts(usableLights: buckets.usable, meta: metaByFileID)
        guard let dominant = EquipmentProfile.dominant(counts) else {
            return naReply(target: target, reason: "nincs elég fejléc-adat a setup meghatározásához", totalUsableSeconds: 0)
        }

        let dominantFrames = buckets.usable.filter { file in
            guard let id = file.id, let meta = metaByFileID[id] else { return false }
            return EquipmentProfile.fingerprint(meta: meta, headerJSON: meta.headerJSON) == dominant
        }

        var totalUsableSeconds: Double = 0
        for file in dominantFrames {
            if let exptime = (file.id.flatMap { metaByFileID[$0] })?.exptime {
                totalUsableSeconds += exptime
            }
        }
        let snr = snrGuidance(totalUsableSeconds: totalUsableSeconds)

        // The most recent (dominant-setup) session date that has at least
        // one rated frame on record -- an unrated recent session is skipped
        // in favor of the latest one we actually have per-frame metrics for.
        let datesDescending = Set(dominantFrames.compactMap(\.sessionDate)).sorted(by: >)
        var chosenDate: String?
        var chosenFrames: [(meta: FITSMetaRecord, rating: RatingRecord)] = []
        for date in datesDescending {
            var rated: [(FITSMetaRecord, RatingRecord)] = []
            for file in dominantFrames where file.sessionDate == date {
                guard let id = file.id, let meta = metaByFileID[id], let rating = try db.rating(fileID: id) else { continue }
                rated.append((meta, rating))
            }
            if !rated.isEmpty {
                chosenDate = date
                chosenFrames = rated
                break
            }
        }

        guard let chosenDate, !chosenFrames.isEmpty else {
            return naReply(
                target: target, reason: "a keretek még nincsenek kiértékelve — futtasd újra: astrotool rate",
                totalUsableSeconds: totalUsableSeconds, snr: snr, setupDescriptor: dominant.descriptor
            )
        }

        let combo = modeCombo(chosenFrames.map(\.meta))
        guard let camera = combo.camera else {
            return naReply(
                target: target, sessionDate: chosenDate, reason: "nincs kamera-azonosító a kiválasztott session kereteihez",
                totalUsableSeconds: totalUsableSeconds, snr: snr, setupDescriptor: dominant.descriptor
            )
        }

        guard let bayerPattern = modeBayerPattern(chosenFrames.map(\.meta)) else {
            return naReply(
                target: target, sessionDate: chosenDate, camera: camera, gain: combo.gain,
                reason: "ez a funkció csak Bayer-szenzoros (színes ASI) kamerákhoz készült — a(z) \(camera) esetén nincs BAYERPAT fejléc (pl. Canon DSLR/mono kamera), a tanácsadó nem tud számolni",
                totalUsableSeconds: totalUsableSeconds, snr: snr, setupDescriptor: dominant.descriptor
            )
        }

        guard let profile = try db.sensorProfile(camera: camera, gain: combo.gain, offset: combo.offset),
              let biasLevel = profile.biasLevelADU, let readNoise = profile.readNoiseE, let egain = profile.egain
        else {
            return naReply(
                target: target, sessionDate: chosenDate, camera: camera, gain: combo.gain,
                reason: "nincs szenzor-profil — futtasd: astrotool sensor --measure",
                totalUsableSeconds: totalUsableSeconds, snr: snr, setupDescriptor: dominant.descriptor
            )
        }

        var rValues: [Double] = []
        var gValues: [Double] = []
        var bValues: [Double] = []
        for (_, rating) in chosenFrames {
            let stats = NativeFrameStats(
                backgroundMedian: rating.background ?? 0,
                saturatedFraction: rating.saturatedFraction ?? 0,
                backgroundMedian00: rating.bg00,
                backgroundMedian01: rating.bg01,
                backgroundMedian10: rating.bg10,
                backgroundMedian11: rating.bg11
            )
            let (r, g, b) = BayerMap.channelMedians(stats: stats, bayerPattern: bayerPattern)
            if let r { rValues.append(r) }
            if let g { gValues.append(g) }
            if let b { bValues.append(b) }
        }

        guard !rValues.isEmpty || !gValues.isEmpty || !bValues.isEmpty else {
            return naReply(
                target: target, sessionDate: chosenDate, camera: camera, gain: combo.gain,
                reason: "nincs per-Bayer háttér-adat ehhez a session-hez (a keretek a bg_00/01/10/11 bevezetése előtt lettek pontozva) — futtasd újra: astrotool rate",
                totalUsableSeconds: totalUsableSeconds, snr: snr, setupDescriptor: dominant.descriptor
            )
        }

        guard let currentSub = median(chosenFrames.compactMap { $0.meta.exptime }), currentSub > 0 else {
            return naReply(
                target: target, sessionDate: chosenDate, camera: camera, gain: combo.gain,
                reason: "nincs exptime-adat a kiválasztott session kereteihez",
                totalUsableSeconds: totalUsableSeconds, snr: snr, setupDescriptor: dominant.descriptor
            )
        }

        var channelRates: [(name: String, rate: Double)] = []
        if let m = median(rValues) { channelRates.append(("R", max(0, (m - biasLevel) * egain / currentSub))) }
        if let m = median(gValues) { channelRates.append(("G", max(0, (m - biasLevel) * egain / currentSub))) }
        if let m = median(bValues) { channelRates.append(("B", max(0, (m - biasLevel) * egain / currentSub))) }

        guard let weakest = channelRates.min(by: { $0.rate < $1.rate }), weakest.rate > 0 else {
            return naReply(
                target: target, sessionDate: chosenDate, camera: camera, gain: combo.gain,
                reason: "a mért égháttér nulla vagy negatív ezen a beállításon — nem lehet sub-hosszt számolni",
                totalUsableSeconds: totalUsableSeconds, snr: snr, setupDescriptor: dominant.descriptor
            )
        }

        let skyRate = weakest.rate
        let configuredC = config.expose.noiseContributionC
        let optimal = (readNoise * readNoise) / (skyRate * (pow(1 + configuredC, 2) - 1))
        let optimalC10 = (readNoise * readNoise) / (skyRate * (pow(1 + alternativeC, 2) - 1))

        let saturatedFraction = median(chosenFrames.compactMap { $0.rating.saturatedFraction })
        let isSaturating = (saturatedFraction ?? 0) > saturationFractionThreshold

        var recommended = optimal
        var capReason: String?
        if isSaturating && optimal > currentSub {
            recommended = currentSub
            capReason = "szaturáció"
        } else if optimal > config.expose.maxSubSeconds {
            recommended = config.expose.maxSubSeconds
            capReason = "maxSubSeconds"
        }

        func readNoiseShare(_ t: Double) -> Double {
            let bt = skyRate * t
            let total = readNoise * readNoise + bt
            guard total > 0 else { return 0 }
            return (1 - (bt / total).squareRoot()) * 100
        }

        let currentShare = readNoiseShare(currentSub)
        let recommendedShare = readNoiseShare(recommended)

        let advice = buildAdvice(
            capReason: capReason, currentSub: currentSub, optimal: optimal, recommended: recommended,
            currentShare: currentShare, weakestChannel: weakest.name, saturatedFraction: saturatedFraction, snr: snr
        )

        return ExposureAdvice(
            target: target, sessionDate: chosenDate, camera: camera, gain: combo.gain,
            currentSubSeconds: currentSub, weakestChannel: weakest.name, skyRateEPerSPx: skyRate,
            readNoiseE: readNoise, optimalSubSeconds: optimal, recommendedSubSeconds: recommended,
            recommendedSubSecondsC10: optimalC10, currentReadNoiseSharePercent: currentShare,
            recommendedReadNoiseSharePercent: recommendedShare, capReason: capReason,
            totalUsableSeconds: totalUsableSeconds, snrPlus10PercentHours: snr.plus10Hours,
            snrPlus3hMultiplier: snr.plus3hMultiplier, setupDescriptor: dominant.descriptor,
            advice: advice, notAvailableReason: nil
        )
    }

    /// One `ExposureAdvice` per target that has at least one usable light
    /// frame on record -- a target that fails a later check (no profile, no
    /// Bayer data, ...) is still INCLUDED, with `notAvailableReason` set,
    /// since that's still useful advice ("run sensor --measure"). Only
    /// targets with zero usable lights are skipped entirely.
    public static func adviseAll(db: Database, config: AstroConfig) throws -> [ExposureAdvice] {
        let allFiles = try db.allFiles(includeMissing: false)
        let lights = allFiles.filter { $0.area == .sessions && $0.role == .light }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in lights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let targets = Set(lights.compactMap(\.target)).sorted()
        var results: [ExposureAdvice] = []
        for target in targets {
            let targetLights = lights.filter { $0.target == target }
            let buckets = FrameSet.lightBuckets(files: targetLights, meta: metaByFileID, config: config)
            guard !buckets.usable.isEmpty else { continue }
            results.append(try advise(target: target, db: db, config: config))
        }
        return results
    }

    // MARK: - Relative-SNR guidance

    private struct SNRGuidance {
        var plus10Hours: Double
        var plus3hMultiplier: Double?
    }

    /// `plus10Hours = 0.21 × T(hours)` solves `√((T+X)/T) = 1.10` for `X`
    /// (`(1.10)² − 1 = 0.21`). `plus3hMultiplier = √((T + 3h) / T)`, `nil`
    /// when `T <= 0` (nothing to take a ratio against).
    private static func snrGuidance(totalUsableSeconds: Double) -> SNRGuidance {
        let hours = totalUsableSeconds / secondsPerHour
        let plus10Hours = 0.21 * hours
        let plus3hMultiplier: Double? = totalUsableSeconds > 0
            ? ((totalUsableSeconds + 3 * secondsPerHour) / totalUsableSeconds).squareRoot()
            : nil
        return SNRGuidance(plus10Hours: plus10Hours, plus3hMultiplier: plus3hMultiplier)
    }

    private static func snrAdviceLine(_ snr: SNRGuidance) -> String? {
        guard let multiplier = snr.plus3hMultiplier else { return nil }
        return "+3 h → relatív SNR ×\(hu(multiplier, 2)); a következő +10%-hoz \(hu(snr.plus10Hours, 2)) h kell"
    }

    // MARK: - Advice phrasing

    private static func buildAdvice(
        capReason: String?, currentSub: Double, optimal: Double, recommended: Double,
        currentShare: Double, weakestChannel: String, saturatedFraction: Double?, snr: SNRGuidance
    ) -> [String] {
        var lines: [String] = []

        // The saturation cap forces `recommended == currentSub` by
        // construction (see `advise`), which would make the generic
        // "current is already close to recommended" check below vacuously
        // true -- checked first so the saturation warning always actually
        // surfaces instead of being masked by an "already fine" message.
        if capReason == "szaturáció" {
            let satPercent = (saturatedFraction ?? 0) * 100
            lines.append(
                "elméletileg \(prettySeconds(optimal)) lenne az ideális sub, de a jelenlegi \(fmtSeconds(currentSub))-nál "
                    + "már szaturálódnak a pixelek (\(hu(satPercent, 2))%) — ne nyújtsd hosszabbra"
            )
        } else if currentSub >= readyShareFraction * recommended {
            lines.append("a mostani \(fmtSeconds(currentSub)) sub rendben van — nem a leolvasási zaj a szűk keresztmetszet")
        } else if capReason == "maxSubSeconds" {
            lines.append(
                "nagyon sötét az égháttér, a leolvasási zaj a(z) \(channelNameHu(weakestChannel)) csatorna zajának "
                    + "\(hu(currentShare, 1))%-a — \(fmtSeconds(recommended))-ig érdemes hosszabbítani (elméletileg "
                    + "\(prettySeconds(optimal)), de guiding/műhold-kockázat miatt nem javasolt hosszabb sub)"
            )
        } else {
            lines.append(
                "a mért égháttér mellett ~\(prettySeconds(optimal)) az ideális sub (most \(fmtSeconds(currentSub)) — "
                    + "a leolvasási zaj a keret zajának \(hu(currentShare, 0))%-a)"
            )
        }

        if let snrLine = snrAdviceLine(snr) {
            lines.append(snrLine)
        }

        return lines
    }

    private static func channelNameHu(_ channel: String) -> String {
        switch channel {
        case "R": return "vörös"
        case "G": return "zöld"
        case "B": return "kék"
        default: return channel
        }
    }

    /// Seconds under 10 minutes are shown as whole/one-decimal seconds;
    /// 10 minutes or more are shown rounded to the nearest minute -- e.g.
    /// `203.5` → `"204 s"`, `1260` → `"21 perc"`.
    private static func prettySeconds(_ seconds: Double) -> String {
        guard seconds >= 600 else { return "\(Int(seconds.rounded())) s" }
        return "\(Int((seconds / 60).rounded())) perc"
    }

    private static func fmtSeconds(_ seconds: Double) -> String {
        if seconds == seconds.rounded() {
            return "\(Int(seconds)) s"
        }
        return "\(hu(seconds, 1)) s"
    }

    /// `%.<digits>f`, ASCII decimal point swapped for the Hungarian decimal
    /// comma (`,`).
    private static func hu(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - n/a replies

    private static func naReply(
        target: String,
        sessionDate: String? = nil,
        camera: String? = nil,
        gain: Double? = nil,
        reason: String,
        totalUsableSeconds: Double,
        snr: SNRGuidance? = nil,
        setupDescriptor: String? = nil
    ) -> ExposureAdvice {
        let effectiveSNR = snr ?? snrGuidance(totalUsableSeconds: totalUsableSeconds)
        var advice = [reason]
        if let snrLine = snrAdviceLine(effectiveSNR) {
            advice.append(snrLine)
        }
        return ExposureAdvice(
            target: target, sessionDate: sessionDate, camera: camera, gain: gain,
            totalUsableSeconds: totalUsableSeconds, snrPlus10PercentHours: effectiveSNR.plus10Hours,
            snrPlus3hMultiplier: effectiveSNR.plus3hMultiplier, setupDescriptor: setupDescriptor,
            advice: advice, notAvailableReason: reason
        )
    }

    // MARK: - Combo / Bayer-pattern selection

    /// The most frequent `(camera, gain, offset)` combo among `metas` --
    /// ties broken by camera name (descending) purely for deterministic
    /// output. `(nil, nil, nil)` when no meta record has a camera at all.
    private static func modeCombo(_ metas: [FITSMetaRecord]) -> (camera: String?, gain: Double?, offset: Double?) {
        struct Key: Hashable {
            let camera: String
            let gain: Double?
            let offset: Double?
        }
        var counts: [Key: Int] = [:]
        for meta in metas {
            guard let camera = meta.instrume else { continue }
            let key = Key(camera: camera, gain: meta.gain, offset: meta.offset)
            counts[key, default: 0] += 1
        }
        guard let best = counts.max(by: { a, b in a.value != b.value ? a.value < b.value : a.key.camera > b.key.camera }) else {
            return (nil, nil, nil)
        }
        return (best.key.camera, best.key.gain, best.key.offset)
    }

    /// The frame's `BAYERPAT` FITS header value, decoded straight from
    /// `header_json` the same way `EquipmentProfile.fingerprint` does. `nil`
    /// for a frame with no decodable header, or no `BAYERPAT` card at all
    /// (mono/DSLR).
    private static func bayerPattern(from headerJSON: String?) -> String? {
        guard let headerJSON, let data = headerJSON.data(using: .utf8),
              let cards = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return FITSHeader(rawValues: cards).string("BAYERPAT")
    }

    /// The most frequent decodable `BAYERPAT` value among `metas`. `nil`
    /// when NONE of them decode one -- the mono/DSLR "this feature doesn't
    /// apply" case.
    private static func modeBayerPattern(_ metas: [FITSMetaRecord]) -> String? {
        var counts: [String: Int] = [:]
        for meta in metas {
            if let pattern = bayerPattern(from: meta.headerJSON) {
                counts[pattern, default: 0] += 1
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Median

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
