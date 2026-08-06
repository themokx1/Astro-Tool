import SwiftUI

/// R9-T6/B16(b): `Súgó ▸ Fogalomtár` -- a plain, always-available reference
/// for the vocabulary this app's numbers/labels assume the reader already
/// knows. Kept static (no live data), 1-2 sentences each, ordered
/// roughly pipeline-first (capture -> processing -> library housekeeping).
struct GlossarySheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Term {
        let name: String
        let definition: String
    }

    private static let terms: [Term] = [
        Term(name: "FWHM", definition: "\"Full Width at Half Maximum\" -- egy csillag fényprofiljának félértékszélessége. A fókusz élességének standard mérőszáma: kisebb FWHM = élesebb kép. Pixelben vagy (pixelméret+fókusz ismeretében) ívmásodpercben mérhető."),
        Term(name: "Kerekség", definition: "Egy csillag alakjának köralakúságtól való eltérése (0 = tökéletes kör). Magas érték kómát, csillag-nyúlást (rossz polárbeállás, autoguiding-hiba) vagy tükör/lencse-hibát jelezhet."),
        Term(name: "z-score", definition: "Egy mérés hány szórásnyira van az átlagtól. A pontozás ezzel jelöli ki a \"kiugró\" (outlier) kereteket -- a `rating.outlierZScore` beállítás (Beállítások ▸ Pontozás & expozíció) szabja meg a küszöböt."),
        Term(name: "Saját döntés", definition: "A felhasználó saját elfogadás/elvetés döntése egy keretről (Átnézés ablak, vagy a keret sorának helyi menüje). Stackelésnél ELSŐBBSÉGET kap a pontszámmal szemben: egy elvetett keret a legjobb pontszám mellett is kimarad a stacklistből."),
        Term(name: "e⁻/s/″²", definition: "Elektron/másodperc/ívmásodperc² -- az égi háttér valódi fényessége, szenzor- és setup-független mértékegységben. Csak mért szenzor-profillal (Szenzor-profilok oldal) számolható; anélkül csak nyers ADU-t látsz, ami setupok között nem összehasonlítható."),
        Term(name: "Airmass", definition: "A légkör optikai vastagsága, amin a fény a célponthoz keresztülhalad, a horizonthoz viszonyítva (zenitben = 1, alacsonyan a horizont felett jóval nagyobb). Alacsony magasságnál a légköri szórás és extinkció miatt romlik a képminőség."),
        Term(name: "Hatékonyság (duty cycle)", definition: "A session tényleges integrációs ideje (a light-keretek összes expozíciós ideje) a felvétel kezdete és vége közti teljes ablakhoz mérve, százalékban -- az Éjszakák oldal oszlopa. Alacsony érték sok állásidőt (felhő, meridián-átfordulás, dithering, hardver-hiba) jelezhet."),
        Term(name: "Felhőzet-előrejelzés (Open-Meteo)", definition: "Opt-in felhőzet-előrejelzés a nyílt Open-Meteo szolgáltatásból (Beállítások ▸ Helyszín). A \"Ma este\" tile és a Naptár \"Felhő\" oszlopa mutatja, alkonytól hajnalig hány százalékban felhős az égbolt -- csak a következő 7 napra, és csak a beállított koordinátát küldi el, semmit a könyvtárból."),
        Term(name: "Látómező (FOV) / FOV-illeszkedés", definition: "A szenzor+optika által lefedett égterület mérete fokban. A Felfedezés oldal ezt veti össze a célpont méretével (\"befér\" / \"mozaik kellene\" / \"túl kicsi a képmezőhöz\"), a könyvtár domináns (leggyakoribb) setupjának medián látómezeje alapján."),
        Term(name: "Karantén", definition: "Az Audit oldal \"Takarítható\"-script célmappája: a talált felesleges/duplikált fájlokat ide MOZGATJA (`mv`), soha nem törli. A karantént a felhasználó üríti ki kézzel, saját döntése alapján."),
        Term(name: "Hardlink", definition: "Két fájlnév, ami ugyanarra a lemezen tárolt adatra mutat (nem másolat) -- ugyanannyi helyet foglal egyszer, mint kétszer. Ezt használja ez az app a kalibráció-linkeléshez és a stack-export-hoz: a session mappájába \"link\"-eli a megosztott calibration_library fájlt, anélkül hogy másolná."),
        Term(name: "Bias", definition: "A szenzor kiolvasási zaját és alapszintjét (offset) rögzítő kalibrációs keret: 0 másodperces (vagy minimális) expozíció, fedett optikával. A dark- és flat-kalibráció egyik bemenete."),
        Term(name: "Dark", definition: "A szenzor hőzaját (dark current) rögzítő kalibrációs keret: ugyanolyan expozíciós idő és hőmérséklet, mint a light kereteknél, fedett optikával. A pixel-szintű hőzaj kivonásához használt."),
        Term(name: "Flat", definition: "A szenzor/optika egyenetlen megvilágítás-érzékenységét (vinjettálás, por) rögzítő kalibrációs keret: egyenletesen megvilágított felület felvétele ugyanazzal a setuppal, mint a light kereteknél."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Fogalomtár").font(.headline)
                Spacer()
                Button("Bezárás") { dismiss() }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(Self.terms.enumerated()), id: \.offset) { _, term in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(term.name).font(.subheadline).bold()
                            Text(term.definition).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 480, height: 520)
    }
}
