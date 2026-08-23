public struct NightBriefingChecklistTemplate: Sendable {
    public init() {}

    public func sections(language: BriefingDocumentLanguage) -> [BriefingChecklistSection] {
        language == .hu ? hungarian : english
    }

    private var hungarian: [BriefingChecklistSection] {
        [
            section("departure", "Indulás előtt", [
                item("camera", "Kamera és optika", "Legyen meg minden adapter és védőkupak."),
                item("mount", "Állvány és mount", "A teherbírás és a stabil talaj együtt számít."),
                item("power", "Tápellátás", "Számolj az egész éjszakával és biztonsági tartalékkal."),
                item("cables", "Kábelek és adattároló", "Egy hiányzó kábel vagy betelt meghajtó megállíthatja az estét."),
                item("dew", "Páravédelem és időjárás", "A pára képminőséget ronthat és az eszközöket is veszélyeztetheti."),
            ]),
            section("setup", "Felállítás", [
                item("stability", "Stabilitás és pólusra állás", "Ellenőrizd, hogy semmi nem mozdul és a követés alapja rendben van."),
                item("cable-route", "Kábelút", "A mount teljes mozgásánál se feszüljön vagy akadjon kábel."),
                item("place-time", "Hely és idő", "A pontos hely és idő kell az ég helyes követéséhez."),
            ]),
            section("before-capture", "Első capture előtt", [
                item("focus", "Fókusz és hűtés", "Várd meg a stabil hőmérsékletet, majd fókuszálj."),
                item("camera-settings", "Gain, offset, binning és szűrő", "Egyezzen a capture-tervvel és a kalibrációs képekkel."),
                item("test-frame", "Tesztkép", "Nézd meg a csillagformát, a histogramot és a keretezést."),
            ]),
            section("during-night", "Éjszaka közben", [
                item("weather-check", "Ég és pára", "A körülmények változhatnak a forecast után is."),
                item("guiding", "Fókusz és guiding", "Időnként ellenőrizd, hogy nem romlik-e lassan a kép."),
                item("storage", "Szabad tárhely", "Maradjon elég hely a teljes tervezett sorozathoz."),
            ]),
            section("shutdown", "Befejezés", [
                item("flats", "Flat-terv", "A flat beállítása illeszkedjen az elkészült képekhez."),
                item("inventory", "Eszközök számbavétele", "Sötétben könnyű egy kábelt vagy adaptert ott hagyni."),
                item("safe-shutdown", "Biztonságos leállítás", "Előbb állítsd le az eszközöket, utána bontsd a tápot."),
            ]),
        ]
    }

    private var english: [BriefingChecklistSection] {
        [
            section("departure", "Before leaving", [
                item("camera", "Camera and optics", "Bring every adapter and protective cap."),
                item("mount", "Tripod and mount", "Capacity and stable ground both matter."),
                item("power", "Power", "Plan for the whole night with a safety reserve."),
                item("cables", "Cables and storage", "One missing cable or full drive can end the night."),
                item("dew", "Dew and weather protection", "Dew can harm image quality and equipment."),
            ]),
            section("setup", "Set up", [
                item("stability", "Stability and polar alignment", "Confirm nothing moves and tracking has a sound foundation."),
                item("cable-route", "Cable route", "Nothing should pull or catch through the mount's full movement."),
                item("place-time", "Place and time", "Accurate place and time are needed to follow the sky."),
            ]),
            section("before-capture", "Before the first capture", [
                item("focus", "Focus and cooling", "Wait for a stable temperature, then focus."),
                item("camera-settings", "Gain, offset, binning and filter", "Match the capture plan and calibration frames."),
                item("test-frame", "Test frame", "Check star shape, histogram and framing."),
            ]),
            section("during-night", "During the night", [
                item("weather-check", "Sky and dew", "Conditions can change after the forecast."),
                item("guiding", "Focus and guiding", "Check occasionally for a slow decline in image quality."),
                item("storage", "Free storage", "Keep enough room for the planned sequence."),
            ]),
            section("shutdown", "Finish", [
                item("flats", "Flat plan", "Match flat settings to the captured lights."),
                item("inventory", "Equipment count", "A cable or adapter is easy to leave behind in the dark."),
                item("safe-shutdown", "Safe shutdown", "Stop devices before disconnecting power."),
            ]),
        ]
    }

    private func section(_ id: String, _ title: String, _ items: [BriefingChecklistItem]) -> BriefingChecklistSection {
        .init(id: id, title: title, items: items)
    }

    private func item(_ id: String, _ title: String, _ explanation: String) -> BriefingChecklistItem {
        .init(id: id, title: title, explanation: explanation)
    }
}
