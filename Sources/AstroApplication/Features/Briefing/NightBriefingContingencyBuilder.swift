public struct NightBriefingContext: Equatable, Sendable {
    public var calibrationGaps: [String]
    public var poorQualityAction: String?

    public init(calibrationGaps: [String] = [], poorQualityAction: String? = nil) {
        self.calibrationGaps = calibrationGaps
        self.poorQualityAction = poorQualityAction
    }
}

public struct NightBriefingContingencyBuilder: Sendable {
    public init() {}

    public func build(draft: NightBriefingDraft, context: NightBriefingContext) -> [BriefingContingency] {
        let backup = draft.targets.first(where: { $0.role == .backup })?.name
        return draft.language == .hu
            ? hungarian(backup: backup, context: context)
            : english(backup: backup, context: context)
    }

    private func hungarian(backup: String?, context: NightBriefingContext) -> [BriefingContingency] {
        let alternative = backup.map { "Válts a megadott tartalék célpontra: \($0)." }
            ?? "Nincs megadott tartalék célpont; az ég és a felszerelés ellenőrzése után dönts."
        let calibration = context.calibrationGaps.isEmpty
            ? "Nincs ismert kalibrációs hiány; a helyszínen is tartsd meg a beállításokat."
            : "Hiányzik: \(context.calibrationGaps.joined(separator: ", ")). Ne változtass olyan beállítást, amelyhez nincs megfelelő kalibráció."
        return [
            .init(id: "late-arrival", title: "Ha később érkezel", action: alternative),
            .init(id: "short-night", title: "Ha rövidebb lesz az éjszaka", action: "Az elsődleges célpont már megadott blokkját rövidítsd; ne sűrítsd össze ellenőrzés nélkül az expozíciókat."),
            .init(id: "clouds", title: "Ha erősödik a felhőzet", action: "Állítsd meg a sorozatot, ellenőrizd a képeket és a felszerelés biztonságát; a forecast nem garancia."),
            .init(id: "primary-unavailable", title: "Ha kiesik a fő célpont", action: alternative),
            .init(id: "calibration", title: "Ha hiányzik kalibráció", action: calibration),
            .init(id: "quality", title: "Ha romlik a képminőség", action: context.poorQualityAction ?? "Állj meg, készíts tesztképet, majd ellenőrizd a fókuszt, párát és guidingot."),
        ]
    }

    private func english(backup: String?, context: NightBriefingContext) -> [BriefingContingency] {
        let alternative = backup.map { "Switch to the selected backup target: \($0)." }
            ?? "No backup target is selected; decide only after checking the sky and equipment."
        let calibration = context.calibrationGaps.isEmpty
            ? "No calibration gap is known; keep the planned settings in the field."
            : "Missing: \(context.calibrationGaps.joined(separator: ", ")). Do not change to settings without matching calibration."
        return [
            .init(id: "late-arrival", title: "If you arrive late", action: alternative),
            .init(id: "short-night", title: "If the night is shorter", action: "Shorten the primary target's existing block; do not compress exposures without checking them."),
            .init(id: "clouds", title: "If cloud increases", action: "Stop the sequence, check the frames and equipment safety; a forecast is not a guarantee."),
            .init(id: "primary-unavailable", title: "If the primary target is unavailable", action: alternative),
            .init(id: "calibration", title: "If calibration is missing", action: calibration),
            .init(id: "quality", title: "If image quality declines", action: context.poorQualityAction ?? "Pause, take a test frame, then check focus, dew and guiding."),
        ]
    }
}
